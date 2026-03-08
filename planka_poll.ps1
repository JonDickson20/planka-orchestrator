# Planka Queue Orchestrator (Multi-Project)
# Persistent poller that scans all project configs and spawns Claude Code agents.

param(
    [string]$Project = "",       # Filter to a single project by name (e.g., -Project "HSP Portal")
    [switch]$Once                # Run one poll cycle then exit (useful for testing)
)

# Global Config
$PLANKA_URL      = "https://planka.jondxn.com/api"
$PLANKA_EMAIL    = "jondickson20@gmail.com"
$PLANKA_PASSWORD = "YL*ZKs9PvMR5PfQrWpiBHQLy"

$POLL_INTERVAL       = 30
$MAX_WORKERS         = 2      # Max simultaneous Claude Code agents (total across all projects)
$MAX_AGENT_MINUTES   = 30     # Kill agents that run longer than this
$MIN_IDEAS           = 10     # Minimum ideas per project before replenishment
$PROJECTS_DIR        = Join-Path $PSScriptRoot "projects"
$AGENTS_DIR          = Join-Path $PSScriptRoot "agents"
$LOG_DIR             = Join-Path $PSScriptRoot "logs"
$WORKTREE_DIR        = Join-Path $PSScriptRoot "worktrees"
$STATUS_FILE         = Join-Path $PSScriptRoot "status.json"

# Bot accounts (each agent type authenticates as its own Planka user)
$BOT_PASSWORD = "Planka4Bots2026"
$BOT_ACCOUNTS = @{
    worker        = "worker_bot"
    deploy        = "deploy_bot"
    "idea-gen"    = "idea_bot"
}
# Maps agent filenames (without .md) to their bot username
$AGENT_BOT_MAP = @{
    "SEO_AUDIT"             = "seo_bot"
    "MARKETING_CONVERSION"  = "marketing_bot"
    "SECURITY_PENTEST"      = "security_bot"
    "ACCESSIBILITY_AUDIT"   = "a11y_bot"
    "PERFORMANCE_AUDIT"     = "perf_bot"
    "VISUAL_QA"             = "visualqa_bot"
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Cloudflare cache purge config
$CF_CONFIG_PATH = "C:\Users\JonDi\Desktop\Hosting\cloudflare.json"

# Ensure log and worktree directories
if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null }
if (-not (Test-Path $WORKTREE_DIR)) { New-Item -ItemType Directory -Path $WORKTREE_DIR -Force | Out-Null }

# State
# Each entry: { process, cardId, startTime, promptFile, logFile, action, worktreePath, mainWorkspace }
$activeJobs = @{}
$script:startedAt = Get-Date -Format "o"

# Write orchestrator status to disk (read by dashboard)
function Write-Status {
    $jobs = @()
    foreach ($entry in $activeJobs.GetEnumerator()) {
        $job = $entry.Value
        $elapsed = [math]::Round(((Get-Date) - $job.startTime).TotalMinutes, 1)
        $logName = if ($job.logFile) { Split-Path $job.logFile -Leaf } else { "" }
        $jobs += @{
            key = $entry.Key
            cardId = $job.cardId
            projectName = ($entry.Key -split ":")[0]
            startTime = $job.startTime.ToString("o")
            elapsedMinutes = $elapsed
            logFile = $logName
        }
    }
    $status = @{
        timestamp = (Get-Date).ToString("o")
        startedAt = $script:startedAt
        pollInterval = $POLL_INTERVAL
        maxWorkers = $MAX_WORKERS
        agentTimeout = $MAX_AGENT_MINUTES
        activeJobs = $jobs
    }
    try {
        $json = $status | ConvertTo-Json -Depth 3 -Compress
        [System.IO.File]::WriteAllText($STATUS_FILE, $json)
    } catch {}
}

# Auth (cached, re-auth only on failure)
$script:token = $null

function Ensure-PlankaToken {
    if (-not $script:token) {
        $script:token = Get-PlankaTokenRaw
    }
}

function Get-PlankaTokenRaw {
    $body = @{ emailOrUsername = $PLANKA_EMAIL; password = $PLANKA_PASSWORD } | ConvertTo-Json
    $r = Invoke-WebRequest -Uri "$PLANKA_URL/access-tokens" -Method Post -Body $body -ContentType "application/json" -UseBasicParsing -TimeoutSec 15
    $data = $r.Content | ConvertFrom-Json
    return $data.item
}

function Planka-Get {
    param([string]$path)
    try {
        $r = Invoke-WebRequest -Uri "$PLANKA_URL$path" -Method Get -Headers @{"Authorization"="Bearer $script:token"} -UseBasicParsing -TimeoutSec 15
        return $r.Content | ConvertFrom-Json
    } catch {
        if ($_.Exception.Response.StatusCode -eq 401) {
            Write-Host "    Token expired, re-authenticating..." -ForegroundColor Yellow
            $script:token = Get-PlankaTokenRaw
            $r = Invoke-WebRequest -Uri "$PLANKA_URL$path" -Method Get -Headers @{"Authorization"="Bearer $script:token"} -UseBasicParsing -TimeoutSec 15
            return $r.Content | ConvertFrom-Json
        }
        throw
    }
}

function Planka-Post {
    param([string]$path, [string]$body)
    try {
        $r = Invoke-WebRequest -Uri "$PLANKA_URL$path" -Method Post -Headers @{"Authorization"="Bearer $script:token"} -Body $body -ContentType "application/json" -UseBasicParsing -TimeoutSec 30
        return $r.Content | ConvertFrom-Json
    } catch {
        if ($_.Exception.Response.StatusCode -eq 401) {
            $script:token = Get-PlankaTokenRaw
            $r = Invoke-WebRequest -Uri "$PLANKA_URL$path" -Method Post -Headers @{"Authorization"="Bearer $script:token"} -Body $body -ContentType "application/json" -UseBasicParsing -TimeoutSec 30
            return $r.Content | ConvertFrom-Json
        }
        throw
    }
}

function Planka-Patch {
    param([string]$path, [string]$body)
    try {
        Invoke-WebRequest -Uri "$PLANKA_URL$path" -Method Patch -Headers @{"Authorization"="Bearer $script:token"} -Body $body -ContentType "application/json" -UseBasicParsing -TimeoutSec 30 | Out-Null
    } catch {
        if ($_.Exception.Response.StatusCode -eq 401) {
            $script:token = Get-PlankaTokenRaw
            Invoke-WebRequest -Uri "$PLANKA_URL$path" -Method Patch -Headers @{"Authorization"="Bearer $script:token"} -Body $body -ContentType "application/json" -UseBasicParsing -TimeoutSec 30 | Out-Null
        } else {
            throw
        }
    }
}

# Purge Cloudflare cache for a subdomain (called after deploy agents finish)
function Purge-CloudflareCache {
    param([string]$subdomain)
    $purgeScript = "C:\Users\JonDi\Desktop\Hosting\purge-cache.ps1"
    if (-not (Test-Path $purgeScript)) { return }
    try {
        & powershell -ExecutionPolicy Bypass -File $purgeScript -Subdomain $subdomain
    } catch {
        Write-Host "    Warning: Cache purge script failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Load Project Configs
function Load-Projects {
    $configs = @()
    $files = Get-ChildItem -Path $PROJECTS_DIR -Filter "*.json" -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        try {
            $cfg = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $configs += $cfg
            Write-Host "  Loaded project: $($cfg.name) (board $($cfg.boardId))" -ForegroundColor DarkCyan
        } catch {
            Write-Host "  WARNING: Failed to load $($f.Name): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    return $configs
}

# Read CLAUDE.md for a project (if it exists)
function Get-ProjectClaudeMd {
    param([string]$workspace)
    $claudeMdPath = Join-Path $workspace "CLAUDE.md"
    if (Test-Path $claudeMdPath) {
        return Get-Content $claudeMdPath -Raw -ErrorAction SilentlyContinue
    }
    return $null
}

# Fetch card comments from Planka API
function Get-CardComments {
    param([string]$cardId)
    try {
        $data = Planka-Get "/cards/$cardId"
        $actions = $data.included.actions
        if ($actions) {
            return @($actions | Where-Object { $_.type -eq "commentCard" } | ForEach-Object { $_.data.text })
        }
    } catch {
        Write-Host "    Warning: Could not fetch comments for card $cardId" -ForegroundColor Yellow
    }
    return @()
}

# Extract branch name from card comments
function Find-BranchName {
    param([string[]]$comments)
    foreach ($comment in $comments) {
        if ($comment -match '(?:branch[:\s]*)?((fix|feature)/[a-zA-Z0-9\-_/]+)') {
            return $Matches[1]
        }
    }
    return $null
}

# Get GitHub compare URL base from workspace git remote
function Get-GitHubCompareBase {
    param([string]$workspace)
    try {
        $remote = & git -C $workspace remote get-url origin 2>$null
        if ($remote -match 'github\.com[:/](.+?)(?:\.git)?$') {
            return "https://github.com/$($Matches[1])/compare/main..."
        }
    } catch {}
    return $null
}

# Create a git worktree for isolated agent work
function Create-Worktree {
    param([string]$workspace, [string]$branchName, [string]$cardId)

    $worktreePath = Join-Path $WORKTREE_DIR $cardId

    # Clean up stale worktree at this path if it exists
    if (Test-Path $worktreePath) {
        & git -C $workspace worktree remove $worktreePath --force 2>&1 | Out-Null
        if (Test-Path $worktreePath) {
            Remove-Item -Path $worktreePath -Recurse -Force -ErrorAction SilentlyContinue
        }
        & git -C $workspace worktree prune 2>&1 | Out-Null
    }

    # Delete stale local branch if it exists
    & git -C $workspace branch -D $branchName 2>&1 | Out-Null

    # Fetch latest main
    $fetchResult = & git -C $workspace fetch origin main 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    Warning: git fetch failed: $fetchResult" -ForegroundColor Yellow
    }

    # Create worktree with new branch from origin/main
    $result = & git -C $workspace worktree add $worktreePath -b $branchName origin/main 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    Failed to create worktree: $result" -ForegroundColor Red
        return $null
    }

    return $worktreePath
}

# Remove a git worktree and clean up the local branch
function Remove-Worktree {
    param([string]$workspace, [string]$worktreePath, [string]$branchName)

    if ($worktreePath -and (Test-Path $worktreePath)) {
        & git -C $workspace worktree remove $worktreePath --force 2>&1 | Out-Null

        # Fallback: remove directory and prune
        if (Test-Path $worktreePath) {
            Remove-Item -Path $worktreePath -Recurse -Force -ErrorAction SilentlyContinue
            & git -C $workspace worktree prune 2>&1 | Out-Null
        }
    }

    # Clean up the local branch (remote branch preserved for review)
    if ($branchName) {
        & git -C $workspace branch -D $branchName 2>&1 | Out-Null
    }
}

# Get list of specialist agent files (everything except FEATURE_IDEAS.md)
function Get-SpecialistAgentNames {
    $names = @()
    $agentFiles = Get-ChildItem -Path $AGENTS_DIR -Filter "*.md" -ErrorAction SilentlyContinue
    foreach ($f in $agentFiles) {
        if ($f.Name -ne "FEATURE_IDEAS.md") {
            $names += $f.Name
        }
    }
    return $names
}

# Agent Spawning
function Spawn-Agent {
    param([string]$cardId, [string]$prompt, [string]$workspace)

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $promptFile = Join-Path $env:TEMP "planka_agent_$cardId.txt"
    $logFile = Join-Path $LOG_DIR "agent_${cardId}_${timestamp}.log"

    $prompt | Out-File -FilePath $promptFile -Encoding utf8 -Force

    $claudePath = "C:\Users\JonDi\.local\bin\claude.exe"
    $proc = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c", "type `"$promptFile`" | `"$claudePath`" -p --dangerously-skip-permissions > `"$logFile`" 2>&1" `
        -WorkingDirectory $workspace -PassThru -NoNewWindow

    return @{
        process     = $proc
        cardId      = $cardId
        promptFile  = $promptFile
        logFile     = $logFile
        startTime   = Get-Date
    }
}

# Check if a project already has an active deploy agent (work agents use worktrees, no locking needed)
function Project-HasActiveDeployAgent {
    param([string]$projectName)
    foreach ($entry in $activeJobs.GetEnumerator()) {
        if ($entry.Key.StartsWith("$projectName`:") -and $entry.Value.action -eq "deploy") {
            return $true
        }
    }
    return $false
}

# Move card to Stuck with error comment
function Move-CardToStuck {
    param([string]$cardId, [string]$stuckListId, [string]$message)
    try {
        Planka-Patch "/cards/$cardId" ('{"listId":"' + $stuckListId + '","position":1}')
        $escapedMsg = $message -replace '\\', '\\\\' -replace '"', '\"' -replace "`n", '\n' -replace "`r", ''
        Planka-Post "/cards/$cardId/comments" ('{"text":"' + $escapedMsg + '"}')
    } catch {
        Write-Host "    Warning: Failed to move card $cardId to Stuck: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Get a list ID for a card's project by looking up the config
function Get-StuckListId {
    param([string]$jobKey)
    $projectName = $jobKey.Split(":")[0]
    $files = Get-ChildItem -Path $PROJECTS_DIR -Filter "*.json" -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        try {
            $cfg = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if ($cfg.name -eq $projectName) { return $cfg.lists.stuck }
        } catch {}
    }
    return $null
}

function Get-WorkingListId {
    param([string]$jobKey)
    $projectName = $jobKey.Split(":")[0]
    $files = Get-ChildItem -Path $PROJECTS_DIR -Filter "*.json" -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        try {
            $cfg = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if ($cfg.name -eq $projectName) { return $cfg.lists.working }
        } catch {}
    }
    return $null
}

# Build Agent Prompt
function Build-AgentPrompt {
    param($card, $action, $listSource, $project, $worktreePath)

    $protocol = Get-Content (Join-Path $PSScriptRoot "QUEUE_WORKER.md") -Raw -ErrorAction SilentlyContinue
    if (-not $protocol) { $protocol = "See QUEUE_WORKER.md for the full protocol." }

    $configJson = $project | ConvertTo-Json -Depth 5

    # Read project CLAUDE.md if available
    $claudeMd = Get-ProjectClaudeMd -workspace $project.workspace
    $claudeMdSection = ""
    if ($claudeMd) {
        $claudeMdSection = @"

PROJECT CLAUDE.MD (coding conventions, architecture, key commands):
$claudeMd
"@
    }

    # Description note
    if ($card.description) {
        $descriptionText = $card.description
    } else {
        $descriptionText = "(No description provided -- work from the card title and any comments below.)"
    }

    # Always fetch card comments for full context
    $comments = Get-CardComments -cardId $card.id
    $commentsSection = ""
    if ($comments.Count -gt 0) {
        $commentsList = ($comments | ForEach-Object { "- $_" }) -join "`n"
        $commentsSection = @"

CARD COMMENTS (additional context from humans or previous agents):
$commentsList
"@
    }

    if ($action -eq "deploy") {
        # Find branch name from comments
        $branchName = Find-BranchName -comments $comments
        if ($branchName) {
            $branchInstruction = "BRANCH NAME: $branchName"
        } else {
            $branchInstruction = "BRANCH NAME: Unknown -- check the card comments via GET /api/cards/$($card.id) and look for fix/* or feature/* branch names."
        }

        $deployedListId = $project.lists.deployed
        $cardIdVal = $card.id
        $cardName = $card.name

        # Docker rebuild + cache purge instructions (if project has a subdomain)
        $dockerStep = ""
        if ($project.subdomain) {
            $sub = $project.subdomain
            $dockerStep = @"
7. DEPLOY TO HOSTING: Rebuild and restart the Docker container so the live site updates:
   Run: cd /c/Users/JonDi/Desktop/Hosting
   Run: docker compose up -d --build $sub
   Run: docker compose ps $sub
   Verify the container is running and healthy.
8. PURGE CLOUDFLARE CACHE: Run the cache purge script so the live site serves fresh content immediately:
   Run: powershell -ExecutionPolicy Bypass -File /c/Users/JonDi/Desktop/Hosting/purge-cache.ps1 -Subdomain $sub
   If the purge script reports no API token configured, that is OK — the Caddy s-maxage=60 header ensures
   Cloudflare's edge cache expires within 60 seconds automatically. Note this in your deploy comment.
   Run: cd $($project.workspace -replace '\\','/')
"@
        }

        $deploySteps = @"
5. git push origin main
6. Delete the branch locally and remotely: git branch -d BRANCHNAME then git push origin --delete BRANCHNAME
$dockerStep
9. Add a comment to the card summarizing what was merged and deployed. Include the branch name.
10. Move card to Deployed: PATCH $PLANKA_URL/cards/$cardIdVal with body {"listId":"$deployedListId","position":1}
"@

        return @"
You are a Planka queue worker operating on the "$($project.name)" project.
A card has been moved to the "Complete" list -- a human approved it and it needs to be deployed.

PROJECT CONFIG:
$configJson
$claudeMdSection

CARD ID: $cardIdVal
CARD NAME: $cardName
CARD DESCRIPTION: $descriptionText
$commentsSection

$branchInstruction

DEPLOY METHOD: $($project.deployMethod)
$(if ($project.deployNotes) { "DEPLOY NOTES: $($project.deployNotes)" })

DEPLOYMENT STEPS:
1. cd to $($project.workspace)
2. git checkout main and git pull origin main
3. git merge $branchName --no-ff -m "Merge ${branchName}: $cardName"
4. Resolve any merge conflicts if they arise.
$deploySteps

Authenticate as Deploy Bot: POST $PLANKA_URL/access-tokens with {"emailOrUsername":"$($BOT_ACCOUNTS['deploy'])","password":"$BOT_PASSWORD"}
Use Invoke-WebRequest -UseBasicParsing for all Planka API calls.

FULL PROTOCOL:
$protocol
"@
    } else {
        if ($listSource -eq $project.lists.fix) { $cardType = "fix" } else { $cardType = "feature" }
        $sanitizedName = $card.name -replace '[^a-zA-Z0-9]','-' -replace '-+','-' -replace '^-|-$',''
        $cardIdVal = $card.id
        $cardName = $card.name
        $reviewListId = $project.lists.readyToReview
        $ghCompareBase = Get-GitHubCompareBase -workspace $project.workspace
        if ($ghCompareBase) {
            $reviewLinkInstruction = "11. Add a GitHub review link in your comment: ${ghCompareBase}${cardType}/$sanitizedName"
        } else {
            $reviewLinkInstruction = ""
        }

        # Worktree-based prompt: agent is already on the correct branch in an isolated worktree
        if ($worktreePath) {
            return @"
You are a Planka queue worker operating on the "$($project.name)" project.
You have been assigned a $cardType card.

PROJECT CONFIG:
$configJson
$claudeMdSection

CARD ID: $cardIdVal
CARD NAME: $cardName
CARD DESCRIPTION: $descriptionText
CARD TYPE: $cardType

WORKTREE MODE: You are working in an isolated git worktree. The branch ${cardType}/$sanitizedName has already been created from the latest main for you.

YOUR MISSION:
1. The card has ALREADY been moved to "Working" for you.
2. Read the card name and description carefully and understand the task.
3. cd to $worktreePath
4. You are already on branch ${cardType}/$sanitizedName (created from latest origin/main). Do NOT run git pull or git checkout -b.
5. Implement the fix/feature in the codebase.
$(if ($project.localDevUrl) { "6. Test your changes against the local dev server at $($project.localDevUrl)." } else { "6. Test your changes as appropriate for the project." })
7. Commit: git add -A then git commit -m "[$cardType] $cardName"
8. Push: git push origin ${cardType}/$sanitizedName
9. Move card to Ready to Review: PATCH $PLANKA_URL/cards/$cardIdVal with body {"listId":"$reviewListId","position":1}
10. Add a comment summarizing your changes and the branch name.
$reviewLinkInstruction
12. Do NOT run git checkout main -- the orchestrator will clean up the worktree automatically.

Authenticate as Worker Bot: POST $PLANKA_URL/access-tokens with {"emailOrUsername":"$($BOT_ACCOUNTS['worker'])","password":"$BOT_PASSWORD"}
Use Invoke-WebRequest -UseBasicParsing for all Planka API calls.

FULL PROTOCOL:
$protocol
"@
        } else {
            # Fallback: non-worktree prompt (shouldn't normally be used for work agents)
            return @"
You are a Planka queue worker operating on the "$($project.name)" project.
You have been assigned a $cardType card.

PROJECT CONFIG:
$configJson
$claudeMdSection

CARD ID: $cardIdVal
CARD NAME: $cardName
CARD DESCRIPTION: $descriptionText
CARD TYPE: $cardType
$commentsSection

YOUR MISSION:
1. The card has ALREADY been moved to "Working" for you.
2. Read the card name, description, and any comments above to fully understand the task.
3. cd to $($project.workspace)
4. git pull origin main then git checkout -b ${cardType}/$sanitizedName
5. Implement the fix/feature in the codebase.
$(if ($project.localDevUrl) { "6. Test your changes against the local dev server at $($project.localDevUrl)." } else { "6. Test your changes as appropriate for the project." })
7. Commit: git add -A then git commit -m "[$cardType] $cardName"
8. Push: git push origin ${cardType}/$sanitizedName
9. Move card to Ready to Review: PATCH $PLANKA_URL/cards/$cardIdVal with body {"listId":"$reviewListId","position":1}
10. Add a comment summarizing your changes and the branch name.
$reviewLinkInstruction
12. git checkout main

Authenticate as Worker Bot: POST $PLANKA_URL/access-tokens with {"emailOrUsername":"$($BOT_ACCOUNTS['worker'])","password":"$BOT_PASSWORD"}
Use Invoke-WebRequest -UseBasicParsing for all Planka API calls.

FULL PROTOCOL:
$protocol
"@
        }
    }
}

# Build Idea Generation Prompt
function Build-IdeaGenPrompt {
    param($project, [string[]]$existingIdeas, [int]$ideasNeeded, [string[]]$specialistAgents)

    $configJson = $project | ConvertTo-Json -Depth 5

    $claudeMd = Get-ProjectClaudeMd -workspace $project.workspace
    $claudeMdSection = ""
    if ($claudeMd) {
        $claudeMdSection = @"

PROJECT CLAUDE.MD (coding conventions, architecture):
$claudeMd
"@
    }

    $existingList = "(none)"
    if ($existingIdeas.Count -gt 0) {
        $existingList = ($existingIdeas | ForEach-Object { "- $_" }) -join "`n"
    }

    $specialistSection = "(none)"
    if ($specialistAgents.Count -gt 0) {
        $specialistLines = @()
        foreach ($agentFile in $specialistAgents) {
            $agentKey = $agentFile -replace '\.md$',''
            $botUser = $AGENT_BOT_MAP[$agentKey]
            if ($botUser) {
                $specialistLines += "- $AGENTS_DIR\$agentFile  -->  Authenticate as: $botUser / $BOT_PASSWORD"
            } else {
                $specialistLines += "- $AGENTS_DIR\$agentFile  -->  Authenticate as: $($BOT_ACCOUNTS['idea-gen']) / $BOT_PASSWORD"
            }
        }
        $specialistSection = $specialistLines -join "`n"
    }

    $ideasListId = $project.lists.ideas
    $featureIdeasMd = Join-Path $AGENTS_DIR "FEATURE_IDEAS.md"

    return @"
You are a Planka queue worker operating on the "$($project.name)" project.
Your task is to generate improvement ideas and create them as cards in the Ideas list.

PROJECT CONFIG:
$configJson
$claudeMdSection

EXISTING IDEAS (do NOT duplicate these):
$existingList

YOUR MISSION:
1. Read the idea generation guide at: $featureIdeasMd
2. Explore the codebase at $($project.workspace) to understand the application.
   Read key files: routes, controllers, views/templates, models, config files, package manifests, etc.
3. Generate $ideasNeeded feature/improvement ideas for the application.
   Think across categories: UX, functionality, data/insights, automation, integrations, error handling.
   If $ideasNeeded is 0, skip this step (the Ideas list already has enough feature ideas).
4. For EACH of the following specialist agent files, read the file and generate 1 additional idea from that specialist's perspective.
   IMPORTANT: Each specialist has its OWN bot account. You MUST authenticate as that specialist's bot when creating its card so the card shows the right author.
   Get a separate auth token for each specialist bot BEFORE creating their card.
$specialistSection
   Read each file to understand what that specialist focuses on, then think about what they would specifically suggest for THIS application based on the code you explored.
5. For EACH idea, create a Planka card using the correct bot's auth token:
   POST $PLANKA_URL/lists/$ideasListId/cards
   Body: {"name":"<clear concise title>","description":"<3-5 sentences: what, why, rough approach>","position":<incrementing number starting at 65536>,"type":"project"}

AUTHENTICATION:
- For FEATURE ideas (step 3), authenticate as Idea Bot: POST $PLANKA_URL/access-tokens with {"emailOrUsername":"$($BOT_ACCOUNTS['idea-gen'])","password":"$BOT_PASSWORD"}
- For SPECIALIST ideas (step 4), authenticate as each specialist's bot listed above (different username for each).
- To get a token: POST $PLANKA_URL/access-tokens with {"emailOrUsername":"<username>","password":"<password>"} -- the response has {"item":"<token>"}
- Use the token as: Authorization: Bearer <token>
- Use Invoke-WebRequest -UseBasicParsing for all Planka API calls.

CARD QUALITY:
- Be SPECIFIC: "Add Redis caching for provider search" not "Improve performance"
- Include the WHY: what problem does this solve or what value does it add?
- Each idea should be a single, self-contained unit of work
- Do NOT duplicate any existing ideas listed above
- Title: concise action phrase (e.g., "Add bulk CSV import for providers")
- Description: 3-5 sentences covering what, why, and rough approach
"@
}

# Clean Up Finished/Timed-Out Agents
function Cleanup-Agents {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $finishedIds = @()

    foreach ($entry in $activeJobs.GetEnumerator()) {
        $job = $entry.Value
        $proc = $job.process
        $key = $entry.Key
        $cardId = $job.cardId

        # Check for timeout
        $elapsed = (Get-Date) - $job.startTime
        if (-not $proc.HasExited -and $elapsed.TotalMinutes -gt $MAX_AGENT_MINUTES) {
            $mins = [math]::Round($elapsed.TotalMinutes, 1)
            Write-Host "[$timestamp] TIMEOUT: $key (ran for $mins min -- killing)" -ForegroundColor Red

            try { $proc.Kill() } catch {}

            # Move card to Stuck (skip for idea-gen -- no real card)
            if ($cardId -ne "idea-gen") {
                $stuckListId = Get-StuckListId -jobKey $key
                if ($stuckListId) {
                    $logTail = ""
                    if ($job.logFile -and (Test-Path $job.logFile)) {
                        $logTail = (Get-Content $job.logFile -Tail 20 -ErrorAction SilentlyContinue) -join "`n"
                    }
                    Move-CardToStuck -cardId $cardId -stuckListId $stuckListId `
                        -message "Agent timed out after $MAX_AGENT_MINUTES minutes. Log tail:`n$logTail"
                }
            } else {
                Write-Host "    Idea generation timed out for $key" -ForegroundColor Yellow
            }

            # Clean up temp prompt file
            if ($job.promptFile -and (Test-Path $job.promptFile)) {
                Remove-Item $job.promptFile -Force -ErrorAction SilentlyContinue
            }

            # Clean up worktree if this was a work agent
            if ($job.worktreePath -and $job.mainWorkspace) {
                Write-Host "    Cleaning up worktree: $($job.worktreePath)" -ForegroundColor DarkGray
                Remove-Worktree -workspace $job.mainWorkspace -worktreePath $job.worktreePath -branchName $job.branchName
            }

            $finishedIds += $key
            continue
        }

        # Check for normal exit
        if ($proc.HasExited) {
            $exitCode = $proc.ExitCode
            $mins = [math]::Round(((Get-Date) - $job.startTime).TotalMinutes, 1)

            # Treat null or 0 exit code as success (cmd.exe piping can return null)
            if ($null -eq $exitCode -or $exitCode -eq 0) {
                Write-Host "[$timestamp] AGENT FINISHED: $key (exit 0, ran $mins min)" -ForegroundColor Green

                # If this was a deploy agent, purge Cloudflare cache as a safety net
                if ($key -match ":(\d+)$" -and $cardId -ne "idea-gen") {
                    # Look up project subdomain from config
                    $projectName = $key.Split(":")[0]
                    $projectFiles = Get-ChildItem -Path $PROJECTS_DIR -Filter "*.json" -ErrorAction SilentlyContinue
                    foreach ($pf in $projectFiles) {
                        try {
                            $pcfg = Get-Content $pf.FullName -Raw | ConvertFrom-Json
                            if ($pcfg.name -eq $projectName -and $pcfg.subdomain) {
                                # Check if card was in Complete list (deploy action)
                                try {
                                    $cardData = Planka-Get "/cards/$cardId"
                                    if ($cardData.item.listId -eq $pcfg.lists.deployed) {
                                        Purge-CloudflareCache -subdomain $pcfg.subdomain
                                    }
                                } catch {}
                            }
                        } catch {}
                    }
                }
            } else {
                if ($cardId -eq "idea-gen") {
                    Write-Host "[$timestamp] IDEA GEN FAILED: $key (exit $exitCode, ran $mins min)" -ForegroundColor Yellow
                } else {
                    Write-Host "[$timestamp] AGENT FAILED: $key (exit $exitCode, ran $mins min)" -ForegroundColor Red

                    # Only move to Stuck if the card is still in Working
                    # (agent may have already moved it to Ready to Review before crashing)
                    $stuckListId = Get-StuckListId -jobKey $key
                    $workingListId = Get-WorkingListId -jobKey $key
                    if ($stuckListId -and $workingListId) {
                        $shouldMove = $false
                        try {
                            $cardData = Planka-Get "/cards/$cardId"
                            if ($cardData.item.listId -eq $workingListId) {
                                $shouldMove = $true
                            } else {
                                Write-Host "    Card already moved (not in Working), skipping Stuck move" -ForegroundColor DarkYellow
                            }
                        } catch {
                            $shouldMove = $true  # If we can't check, try to move anyway
                        }

                        if ($shouldMove) {
                            $logTail = ""
                            if ($job.logFile -and (Test-Path $job.logFile)) {
                                $logTail = (Get-Content $job.logFile -Tail 20 -ErrorAction SilentlyContinue) -join "`n"
                            }
                            Move-CardToStuck -cardId $cardId -stuckListId $stuckListId `
                                -message "Agent exited with code $exitCode after $mins min."
                        }
                    }
                }
            }

            # Clean up temp prompt file
            if ($job.promptFile -and (Test-Path $job.promptFile)) {
                Remove-Item $job.promptFile -Force -ErrorAction SilentlyContinue
            }

            # Clean up worktree if this was a work agent
            if ($job.worktreePath -and $job.mainWorkspace) {
                Write-Host "    Cleaning up worktree: $($job.worktreePath)" -ForegroundColor DarkGray
                Remove-Worktree -workspace $job.mainWorkspace -worktreePath $job.worktreePath -branchName $job.branchName
            }

            $finishedIds += $key
        }
    }

    foreach ($id in $finishedIds) { $activeJobs.Remove($id) }
}

# Process a Single Project Board
function Process-Board {
    param($project, [ref]$slots)

    $boardId = $project.boardId
    $lists   = $project.lists

    try {
        $board = Planka-Get "/boards/$boardId"
        $cards = $board.included.cards
    } catch {
        Write-Host "    API error for $($project.name): $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    # Priority 1: Complete list (deploy) -- per-project locking for deploys only
    if (-not (Project-HasActiveDeployAgent -projectName $project.name)) {
        $completeCards = @($cards | Where-Object { $_.listId -eq $lists.complete -and -not $activeJobs.ContainsKey("$($project.name):$($_.id)") })
        foreach ($card in $completeCards) {
            if ($slots.Value -le 0) { return }
            Write-Host "    DEPLOYING: $($card.name)" -ForegroundColor Green
            $prompt = Build-AgentPrompt -card $card -action "deploy" -listSource $lists.complete -project $project
            $agentInfo = Spawn-Agent -cardId $card.id -prompt $prompt -workspace $project.workspace
            $agentInfo.action = "deploy"
            $agentInfo.worktreePath = $null
            $agentInfo.mainWorkspace = $project.workspace
            $agentInfo.branchName = $null
            $activeJobs["$($project.name):$($card.id)"] = $agentInfo
            $slots.Value--
            break  # One deploy at a time per project
        }
    }

    # Priority 2: Fix list -- each agent gets an isolated worktree
    $fixCards = @($cards | Where-Object { $_.listId -eq $lists.fix -and -not $activeJobs.ContainsKey("$($project.name):$($_.id)") })
    foreach ($card in $fixCards) {
        if ($slots.Value -le 0) { return }

        $sanitizedName = $card.name -replace '[^a-zA-Z0-9]','-' -replace '-+','-' -replace '^-|-$',''
        $branchName = "fix/$sanitizedName"

        $worktreePath = Create-Worktree -workspace $project.workspace -branchName $branchName -cardId $card.id
        if (-not $worktreePath) {
            Write-Host "    Failed to create worktree for $($card.name), skipping" -ForegroundColor Red
            continue
        }

        Write-Host "    CLAIMING FIX: $($card.name) (worktree: $worktreePath)" -ForegroundColor Cyan
        Planka-Patch "/cards/$($card.id)" ('{"listId":"' + $lists.working + '","position":1}')
        $prompt = Build-AgentPrompt -card $card -action "work" -listSource $lists.fix -project $project -worktreePath $worktreePath
        $agentInfo = Spawn-Agent -cardId $card.id -prompt $prompt -workspace $worktreePath
        $agentInfo.action = "work"
        $agentInfo.worktreePath = $worktreePath
        $agentInfo.mainWorkspace = $project.workspace
        $agentInfo.branchName = $branchName
        $activeJobs["$($project.name):$($card.id)"] = $agentInfo
        $slots.Value--
        # No return -- allow multiple work agents per project via worktrees
    }

    # Priority 3: Feature list (only if no fix cards)
    if ($fixCards.Count -eq 0) {
        $featureCards = @($cards | Where-Object { $_.listId -eq $lists.feature -and -not $activeJobs.ContainsKey("$($project.name):$($_.id)") })
        foreach ($card in $featureCards) {
            if ($slots.Value -le 0) { return }

            $sanitizedName = $card.name -replace '[^a-zA-Z0-9]','-' -replace '-+','-' -replace '^-|-$',''
            $branchName = "feature/$sanitizedName"

            $worktreePath = Create-Worktree -workspace $project.workspace -branchName $branchName -cardId $card.id
            if (-not $worktreePath) {
                Write-Host "    Failed to create worktree for $($card.name), skipping" -ForegroundColor Red
                continue
            }

            Write-Host "    CLAIMING FEATURE: $($card.name) (worktree: $worktreePath)" -ForegroundColor Magenta
            Planka-Patch "/cards/$($card.id)" ('{"listId":"' + $lists.working + '","position":1}')
            $prompt = Build-AgentPrompt -card $card -action "work" -listSource $lists.feature -project $project -worktreePath $worktreePath
            $agentInfo = Spawn-Agent -cardId $card.id -prompt $prompt -workspace $worktreePath
            $agentInfo.action = "work"
            $agentInfo.worktreePath = $worktreePath
            $agentInfo.mainWorkspace = $project.workspace
            $agentInfo.branchName = $branchName
            $activeJobs["$($project.name):$($card.id)"] = $agentInfo
            $slots.Value--
            # No return -- allow multiple work agents per project via worktrees
        }
    }

    # Priority 4: Ideas replenishment (only when no work cards exist)
    if ($lists.ideas) {
        $ideasCards = @($cards | Where-Object { $_.listId -eq $lists.ideas })
        if ($ideasCards.Count -lt $MIN_IDEAS) {
            if ($slots.Value -le 0) { return }
            $ideasNeeded = $MIN_IDEAS - $ideasCards.Count
            $existingTitles = @($ideasCards | ForEach-Object { $_.name })
            $specialists = Get-SpecialistAgentNames
            Write-Host "    IDEAS LOW ($($ideasCards.Count)/$MIN_IDEAS): spawning idea gen agent (+$($specialists.Count) specialist)" -ForegroundColor DarkMagenta
            $prompt = Build-IdeaGenPrompt -project $project -existingIdeas $existingTitles -ideasNeeded $ideasNeeded -specialistAgents $specialists
            $agentInfo = Spawn-Agent -cardId "idea-gen" -prompt $prompt -workspace $project.workspace
            $activeJobs["$($project.name):idea-gen"] = $agentInfo
            $slots.Value--
            return
        }
    }
}

# Main
if ($Project) { $modeLabel = "Single project: $Project" } else { $modeLabel = "All projects" }
if ($Once) { $loopLabel = "Single run" } else { $loopLabel = "Continuous" }

Write-Host "=========================================="
Write-Host "  Planka Queue Orchestrator"
Write-Host "  Mode: $modeLabel ($loopLabel)"
Write-Host "  Max workers: $MAX_WORKERS"
Write-Host "  Agent timeout: $MAX_AGENT_MINUTES min"
Write-Host "  Poll interval: ${POLL_INTERVAL}s"
Write-Host "  Logs: $LOG_DIR"
if (-not $Once) { Write-Host "  Press Ctrl+C to stop" }
Write-Host "=========================================="
Write-Host ""
Write-Host "Loading projects from: $PROJECTS_DIR"

$projects = Load-Projects

# Validate -Project filter
if ($Project) {
    $matched = $false
    foreach ($p in $projects) {
        if ($p.name -eq $Project) { $matched = $true; break }
    }
    if (-not $matched) {
        Write-Host "No project found matching '$Project'. Available projects:" -ForegroundColor Red
        foreach ($p in $projects) { Write-Host "  - $($p.name)" -ForegroundColor Yellow }
        exit 1
    }
}

if ($projects.Count -eq 0) {
    Write-Host "No project configs found in $PROJECTS_DIR. Add a .json file to get started." -ForegroundColor Yellow
    Write-Host "See QUEUE_WORKER.md for the config schema."
    exit 1
}

$monitorCount = if ($Project) { 1 } else { $projects.Count }
Write-Host ""
Write-Host "Monitoring $monitorCount project(s). Starting poll loop..."
Write-Host ""

# Initial auth
Ensure-PlankaToken

while ($true) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Clean up finished/timed-out agents
    Cleanup-Agents
    Write-Status

    # Check capacity
    $slotsAvailable = $MAX_WORKERS - $activeJobs.Count
    if ($slotsAvailable -le 0) {
        if ($Once -and $activeJobs.Count -eq 0) { break }
        Write-Host "[$timestamp] All $MAX_WORKERS worker slots occupied. Waiting..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds $POLL_INTERVAL
        continue
    }

    # Reload projects each cycle (hot-reload)
    $projects = [System.Collections.ArrayList]@()
    $files = Get-ChildItem -Path $PROJECTS_DIR -Filter "*.json" -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        try {
            $cfg = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $projects.Add($cfg) | Out-Null
        } catch {}
    }

    # Process each project board (skip non-matching if -Project filter is set)
    $claimedAny = $false
    foreach ($proj in $projects) {
        if ($Project -and $proj.name -ne $Project) { continue }
        if ($slotsAvailable -le 0) { break }
        Write-Host "[$timestamp] Checking: $($proj.name)..." -ForegroundColor DarkGray
        $before = $activeJobs.Count
        Process-Board -project $proj -slots ([ref]$slotsAvailable)
        if ($activeJobs.Count -gt $before) { $claimedAny = $true }
    }

    if ($activeJobs.Count -gt 0) {
        $summary = ($activeJobs.GetEnumerator() | ForEach-Object {
            $elapsed = [math]::Round(((Get-Date) - $_.Value.startTime).TotalMinutes, 1)
            "$($_.Key) (${elapsed}m)"
        }) -join ", "
        Write-Host "[$timestamp] Active: $summary. Waiting ${POLL_INTERVAL}s..."
    } else {
        Write-Host "[$timestamp] No actionable cards across $($projects.Count) project(s). Waiting ${POLL_INTERVAL}s..."
        # In -Once mode, if nothing was claimed and nothing is active, exit
        if ($Once) {
            Write-Host "[$timestamp] -Once mode: no work found. Exiting." -ForegroundColor Yellow
            break
        }
    }

    # In -Once mode, wait for active agents to finish then exit
    if ($Once -and $claimedAny) {
        Write-Host "[$timestamp] -Once mode: waiting for agent(s) to finish..."
        while ($activeJobs.Count -gt 0) {
            Start-Sleep -Seconds 5
            Cleanup-Agents
            if ($activeJobs.Count -gt 0) {
                $summary = ($activeJobs.GetEnumerator() | ForEach-Object {
                    $elapsed = [math]::Round(((Get-Date) - $_.Value.startTime).TotalMinutes, 1)
                    "$($_.Key) (${elapsed}m)"
                }) -join ", "
                Write-Host "  Still running: $summary"
            }
        }
        Write-Host "[$timestamp] -Once mode: all agents finished. Exiting." -ForegroundColor Green
        break
    }

    Start-Sleep -Seconds $POLL_INTERVAL
}
