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
$PROJECTS_DIR        = Join-Path $PSScriptRoot "projects"
$LOG_DIR             = Join-Path $PSScriptRoot "logs"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Ensure log directory
if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null }

# State
# Each entry: { process, cardId, projectName, startTime, promptFile, logFile }
$activeJobs = @{}

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

# Check if a project already has an active agent
function Project-HasActiveAgent {
    param([string]$projectName)
    foreach ($entry in $activeJobs.GetEnumerator()) {
        if ($entry.Key.StartsWith("$projectName`:")) {
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
        Planka-Post "/cards/$cardId/comment-actions" ('{"text":"' + $escapedMsg + '"}')
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
    param($card, $action, $listSource, $project)

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
        $descriptionText = "(No description provided -- work from the card title alone.)"
    }

    if ($action -eq "deploy") {
        # Fetch comments and find branch name
        $comments = Get-CardComments -cardId $card.id
        $branchName = Find-BranchName -comments $comments
        if ($branchName) {
            $branchInstruction = "BRANCH NAME: $branchName"
        } else {
            $branchInstruction = "BRANCH NAME: Unknown -- check the card comments via GET /api/cards/$($card.id) and look for fix/* or feature/* branch names."
        }

        $deployedListId = $project.lists.deployed
        $cardIdVal = $card.id
        $cardName = $card.name

        if ($project.deployMethod -eq "git-push-main") {
            $deploySteps = @"
5. git push origin main (triggers auto-deploy)
6. Delete the branch locally and remotely: git branch -d BRANCHNAME then git push origin --delete BRANCHNAME
7. Add a comment to the card: 'Merged to main and deployed to production.'
8. Move card to Deployed: PATCH $PLANKA_URL/cards/$cardIdVal with body {"listId":"$deployedListId","position":1}
"@
        } elseif ($project.deployMethod -eq "manual") {
            $deploySteps = @"
5. git push origin main
6. Delete the branch locally and remotely: git branch -d BRANCHNAME then git push origin --delete BRANCHNAME
7. Add a comment to the card: 'Merged to main. Awaiting manual deploy.'
8. Move card to Deployed: PATCH $PLANKA_URL/cards/$cardIdVal with body {"listId":"$deployedListId","position":1}
"@
        } else {
            $deploySteps = @"
5. git push origin main
6. Run deploy script if applicable.
7. Clean up branches.
8. Add a comment and move card to Deployed.
"@
        }

        return @"
You are a Planka queue worker operating on the "$($project.name)" project.
A card has been moved to the "Complete" list -- a human approved it and it needs to be deployed.

PROJECT CONFIG:
$configJson
$claudeMdSection

CARD ID: $cardIdVal
CARD NAME: $cardName
CARD DESCRIPTION: $descriptionText

$branchInstruction

DEPLOY METHOD: $($project.deployMethod)
$(if ($project.deployNotes) { "DEPLOY NOTES: $($project.deployNotes)" })

DEPLOYMENT STEPS:
1. cd to $($project.workspace)
2. git checkout main and git pull origin main
3. git merge $branchName --no-ff -m "Merge ${branchName}: $cardName"
4. Resolve any merge conflicts if they arise.
$deploySteps

Authenticate first: POST $PLANKA_URL/access-tokens with {"emailOrUsername":"$PLANKA_EMAIL","password":"$PLANKA_PASSWORD"}
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

YOUR MISSION:
1. The card has ALREADY been moved to "Working" for you.
2. Read the card name and description carefully and understand the task.
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

Authenticate first: POST $PLANKA_URL/access-tokens with {"emailOrUsername":"$PLANKA_EMAIL","password":"$PLANKA_PASSWORD"}
Use Invoke-WebRequest -UseBasicParsing for all Planka API calls.

FULL PROTOCOL:
$protocol
"@
    }
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

            # Move card to Stuck
            $stuckListId = Get-StuckListId -jobKey $key
            if ($stuckListId) {
                $logTail = ""
                if ($job.logFile -and (Test-Path $job.logFile)) {
                    $logTail = (Get-Content $job.logFile -Tail 20 -ErrorAction SilentlyContinue) -join "`n"
                }
                Move-CardToStuck -cardId $cardId -stuckListId $stuckListId `
                    -message "Agent timed out after $MAX_AGENT_MINUTES minutes. Log tail:`n$logTail"
            }

            # Clean up temp prompt file
            if ($job.promptFile -and (Test-Path $job.promptFile)) {
                Remove-Item $job.promptFile -Force -ErrorAction SilentlyContinue
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

            # Clean up temp prompt file
            if ($job.promptFile -and (Test-Path $job.promptFile)) {
                Remove-Item $job.promptFile -Force -ErrorAction SilentlyContinue
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

    # Per-project locking: skip if this project already has an active agent
    if (Project-HasActiveAgent -projectName $project.name) {
        Write-Host "    $($project.name): agent already active, skipping" -ForegroundColor DarkYellow
        return
    }

    try {
        $board = Planka-Get "/boards/$boardId"
        $cards = $board.included.cards
    } catch {
        Write-Host "    API error for $($project.name): $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    # Priority 1: Complete list (deploy)
    $completeCards = @($cards | Where-Object { $_.listId -eq $lists.complete -and -not $activeJobs.ContainsKey("$($project.name):$($_.id)") })
    foreach ($card in $completeCards) {
        if ($slots.Value -le 0) { return }
        Write-Host "    DEPLOYING: $($card.name)" -ForegroundColor Green
        $prompt = Build-AgentPrompt -card $card -action "deploy" -listSource $lists.complete -project $project
        $agentInfo = Spawn-Agent -cardId $card.id -prompt $prompt -workspace $project.workspace
        $activeJobs["$($project.name):$($card.id)"] = $agentInfo
        $slots.Value--
        return  # One agent per project
    }

    # Priority 2: Fix list
    $fixCards = @($cards | Where-Object { $_.listId -eq $lists.fix -and -not $activeJobs.ContainsKey("$($project.name):$($_.id)") })
    foreach ($card in $fixCards) {
        if ($slots.Value -le 0) { return }
        Write-Host "    CLAIMING FIX: $($card.name)" -ForegroundColor Cyan
        Planka-Patch "/cards/$($card.id)" ('{"listId":"' + $lists.working + '","position":1}')
        $prompt = Build-AgentPrompt -card $card -action "work" -listSource $lists.fix -project $project
        $agentInfo = Spawn-Agent -cardId $card.id -prompt $prompt -workspace $project.workspace
        $activeJobs["$($project.name):$($card.id)"] = $agentInfo
        $slots.Value--
        return  # One agent per project
    }

    # Priority 3: Feature list (only if no fix cards)
    if ($fixCards.Count -eq 0) {
        $featureCards = @($cards | Where-Object { $_.listId -eq $lists.feature -and -not $activeJobs.ContainsKey("$($project.name):$($_.id)") })
        foreach ($card in $featureCards) {
            if ($slots.Value -le 0) { return }
            Write-Host "    CLAIMING FEATURE: $($card.name)" -ForegroundColor Magenta
            Planka-Patch "/cards/$($card.id)" ('{"listId":"' + $lists.working + '","position":1}')
            $prompt = Build-AgentPrompt -card $card -action "work" -listSource $lists.feature -project $project
            $agentInfo = Spawn-Agent -cardId $card.id -prompt $prompt -workspace $project.workspace
            $activeJobs["$($project.name):$($card.id)"] = $agentInfo
            $slots.Value--
            return  # One agent per project
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
