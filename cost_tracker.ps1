# Cost Tracker Module for Planka Orchestrator
# Parses agent log files for Claude API usage stats and tracks per-card costs.

$COST_DATA_DIR  = Join-Path $PSScriptRoot "data"
$COST_DATA_FILE = Join-Path $COST_DATA_DIR "costs.json"

# Ensure data directory exists
if (-not (Test-Path $COST_DATA_DIR)) { New-Item -ItemType Directory -Path $COST_DATA_DIR -Force | Out-Null }

# Initialize costs file if missing
if (-not (Test-Path $COST_DATA_FILE)) {
    '{"runs":[]}' | Out-File -FilePath $COST_DATA_FILE -Encoding utf8 -Force
}

function Parse-AgentLog {
    <#
    .SYNOPSIS
    Parse a stream-json agent log file for usage stats from the final result message.
    Falls back to regex patterns if the log is plain text.
    Returns a hashtable with inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens, costUsd, durationMs, numTurns.
    #>
    param([string]$logFile)

    $result = @{
        inputTokens          = $null
        outputTokens         = $null
        cacheReadTokens      = $null
        cacheCreationTokens  = $null
        costUsd              = $null
        durationMs           = $null
        numTurns             = $null
    }

    if (-not $logFile -or -not (Test-Path $logFile)) { return $result }

    $lines = @(Get-Content $logFile -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { return $result }

    # Strategy 1: Parse stream-json format (NDJSON).
    # The final line(s) should contain a "result" message with cost/usage data.
    # Read from the end to find the result message.
    for ($i = $lines.Count - 1; $i -ge [Math]::Max(0, $lines.Count - 10); $i--) {
        $line = $lines[$i].Trim()
        if (-not $line.StartsWith("{")) { continue }

        try {
            $json = $line | ConvertFrom-Json -ErrorAction Stop

            if ($json.type -eq "result") {
                if ($null -ne $json.usage) {
                    $result.inputTokens         = $json.usage.input_tokens
                    $result.outputTokens         = $json.usage.output_tokens
                    $result.cacheReadTokens      = $json.usage.cache_read_input_tokens
                    $result.cacheCreationTokens  = $json.usage.cache_creation_input_tokens
                }
                if ($null -ne $json.cost_usd)      { $result.costUsd    = [double]$json.cost_usd }
                if ($null -ne $json.total_cost_usd) { $result.costUsd    = [double]$json.total_cost_usd }
                if ($null -ne $json.duration_ms)    { $result.durationMs = [int]$json.duration_ms }
                if ($null -ne $json.num_turns)      { $result.numTurns   = [int]$json.num_turns }
                return $result
            }
        } catch {
            # Not valid JSON, try next line
        }
    }

    # Strategy 2: Regex fallback for plain-text logs or other formats.
    $fullText = $lines -join "`n"

    # Match patterns like: "Total cost: $1.23" or "cost_usd: 1.23"
    if ($fullText -match 'cost[_\s]*(?:usd)?[:\s]*\$?([\d]+\.[\d]+)') {
        $result.costUsd = [double]$Matches[1]
    }
    # Match: "input_tokens: 50000" or "Input tokens: 50,000"
    if ($fullText -match 'input[_\s]*tokens[:\s]*([\d,]+)') {
        $result.inputTokens = [int]($Matches[1] -replace ',','')
    }
    # Match: "output_tokens: 10000"
    if ($fullText -match 'output[_\s]*tokens[:\s]*([\d,]+)') {
        $result.outputTokens = [int]($Matches[1] -replace ',','')
    }

    return $result
}

function Extract-AgentResultText {
    <#
    .SYNOPSIS
    Extract human-readable result text from a stream-json log file.
    Used for stuck-card messages and log tails.
    Falls back to raw last N lines if not stream-json.
    #>
    param([string]$logFile, [int]$tailLines = 20)

    if (-not $logFile -or -not (Test-Path $logFile)) { return "" }

    $lines = @(Get-Content $logFile -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { return "" }

    # Try to extract text content from stream-json
    $textParts = @()
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if (-not $trimmed.StartsWith("{")) { continue }
        try {
            $json = $trimmed | ConvertFrom-Json -ErrorAction Stop
            # assistant messages contain the agent's text output
            if ($json.type -eq "assistant" -and $json.message -and $json.message.content) {
                foreach ($block in $json.message.content) {
                    if ($block.type -eq "text" -and $block.text) {
                        $textParts += $block.text
                    }
                }
            }
            # result message has a "result" field with final text
            if ($json.type -eq "result" -and $json.result) {
                $textParts += $json.result
            }
        } catch {
            # Not JSON -- treat as plain text
            $textParts += $line
        }
    }

    if ($textParts.Count -gt 0) {
        $allText = $textParts -join "`n"
        $allLines = $allText -split "`n"
        if ($allLines.Count -gt $tailLines) {
            return ($allLines | Select-Object -Last $tailLines) -join "`n"
        }
        return $allText
    }

    # Fallback: raw tail
    return ($lines | Select-Object -Last $tailLines) -join "`n"
}

function Record-AgentRun {
    <#
    .SYNOPSIS
    Record a completed agent run in the costs data file.
    #>
    param(
        [string]$cardId,
        [string]$cardName,
        [string]$projectName,
        [datetime]$startTime,
        [datetime]$endTime,
        [double]$durationMinutes,
        [int]$exitCode,
        [string]$logFile,
        [hashtable]$parsedUsage
    )

    # Load existing data
    $data = Get-Content $COST_DATA_FILE -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $data -or -not $data.runs) {
        $data = @{ runs = @() }
    }

    # Build run record
    $run = @{
        cardId              = $cardId
        cardName            = $cardName
        projectName         = $projectName
        startTime           = $startTime.ToString("o")
        endTime             = $endTime.ToString("o")
        durationMinutes     = [math]::Round($durationMinutes, 2)
        exitCode            = $exitCode
        logFile             = if ($logFile) { Split-Path $logFile -Leaf } else { $null }
        inputTokens         = $parsedUsage.inputTokens
        outputTokens        = $parsedUsage.outputTokens
        cacheReadTokens     = $parsedUsage.cacheReadTokens
        cacheCreationTokens = $parsedUsage.cacheCreationTokens
        costUsd             = $parsedUsage.costUsd
        durationMs          = $parsedUsage.durationMs
        numTurns            = $parsedUsage.numTurns
    }

    # Append to runs array
    $runsList = [System.Collections.ArrayList]@($data.runs)
    $runsList.Add($run) | Out-Null

    # Save
    @{ runs = $runsList } | ConvertTo-Json -Depth 5 | Out-File -FilePath $COST_DATA_FILE -Encoding utf8 -Force
    return $run
}

function Get-CostSummary {
    <#
    .SYNOPSIS
    Generate cost summary grouped by day and project.
    Returns a hashtable with daily and weekly totals.
    #>
    $data = Get-Content $COST_DATA_FILE -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $data -or -not $data.runs -or $data.runs.Count -eq 0) {
        return @{
            totalRuns     = 0
            totalCostUsd  = 0
            totalMinutes  = 0
            today         = @{ runs = 0; costUsd = 0; minutes = 0 }
            thisWeek      = @{ runs = 0; costUsd = 0; minutes = 0 }
            byProject     = @{}
        }
    }

    $now       = Get-Date
    $todayStr  = $now.ToString("yyyy-MM-dd")
    $weekStart = $now.AddDays(-($now.DayOfWeek.value__)).Date  # Sunday

    $totalRuns    = 0
    $totalCost    = 0.0
    $totalMinutes = 0.0
    $todayRuns    = 0
    $todayCost    = 0.0
    $todayMinutes = 0.0
    $weekRuns     = 0
    $weekCost     = 0.0
    $weekMinutes  = 0.0
    $byProject    = @{}

    foreach ($run in $data.runs) {
        $totalRuns++
        $runCost = if ($null -ne $run.costUsd) { [double]$run.costUsd } else { 0 }
        $runMins = if ($null -ne $run.durationMinutes) { [double]$run.durationMinutes } else { 0 }
        $totalCost    += $runCost
        $totalMinutes += $runMins

        # Parse date
        $runDate = $null
        try { $runDate = [datetime]::Parse($run.endTime) } catch {
            try { $runDate = [datetime]::Parse($run.startTime) } catch {}
        }

        if ($runDate) {
            if ($runDate.ToString("yyyy-MM-dd") -eq $todayStr) {
                $todayRuns++
                $todayCost    += $runCost
                $todayMinutes += $runMins
            }
            if ($runDate -ge $weekStart) {
                $weekRuns++
                $weekCost    += $runCost
                $weekMinutes += $runMins
            }
        }

        # Per-project
        $proj = if ($run.projectName) { $run.projectName } else { "Unknown" }
        if (-not $byProject.ContainsKey($proj)) {
            $byProject[$proj] = @{ runs = 0; costUsd = 0.0; minutes = 0.0 }
        }
        $byProject[$proj].runs    += 1
        $byProject[$proj].costUsd += $runCost
        $byProject[$proj].minutes += $runMins
    }

    return @{
        totalRuns    = $totalRuns
        totalCostUsd = [math]::Round($totalCost, 4)
        totalMinutes = [math]::Round($totalMinutes, 1)
        today        = @{ runs = $todayRuns;  costUsd = [math]::Round($todayCost, 4);  minutes = [math]::Round($todayMinutes, 1) }
        thisWeek     = @{ runs = $weekRuns;   costUsd = [math]::Round($weekCost, 4);   minutes = [math]::Round($weekMinutes, 1) }
        byProject    = $byProject
    }
}

function Write-CostSummary {
    <#
    .SYNOPSIS
    Print a formatted cost summary to the console for orchestrator logs.
    #>
    $summary = Get-CostSummary

    if ($summary.totalRuns -eq 0) {
        Write-Host "  Cost Tracker: No runs recorded yet." -ForegroundColor DarkGray
        return
    }

    Write-Host ""
    Write-Host "  ========== Cost Summary ==========" -ForegroundColor Cyan
    Write-Host "  Today:     $($summary.today.runs) runs, $($summary.today.minutes) min" -ForegroundColor White -NoNewline
    if ($summary.today.costUsd -gt 0) {
        Write-Host ", `$$($summary.today.costUsd)" -ForegroundColor Yellow
    } else {
        Write-Host ""
    }
    Write-Host "  This Week: $($summary.thisWeek.runs) runs, $($summary.thisWeek.minutes) min" -ForegroundColor White -NoNewline
    if ($summary.thisWeek.costUsd -gt 0) {
        Write-Host ", `$$($summary.thisWeek.costUsd)" -ForegroundColor Yellow
    } else {
        Write-Host ""
    }
    Write-Host "  All Time:  $($summary.totalRuns) runs, $($summary.totalMinutes) min" -ForegroundColor White -NoNewline
    if ($summary.totalCostUsd -gt 0) {
        Write-Host ", `$$($summary.totalCostUsd)" -ForegroundColor Yellow
    } else {
        Write-Host ""
    }

    if ($summary.byProject.Count -gt 0) {
        Write-Host "  --- By Project ---" -ForegroundColor DarkCyan
        foreach ($proj in $summary.byProject.GetEnumerator()) {
            $costStr = if ($proj.Value.costUsd -gt 0) { " (`$$($proj.Value.costUsd))" } else { "" }
            Write-Host "    $($proj.Key): $($proj.Value.runs) runs, $($proj.Value.minutes) min$costStr" -ForegroundColor Gray
        }
    }
    Write-Host "  ===================================" -ForegroundColor Cyan
    Write-Host ""
}

function Format-CostComment {
    <#
    .SYNOPSIS
    Format a cost summary string for posting as a Planka comment on a card.
    #>
    param([hashtable]$run)

    $parts = @("Agent run completed in $($run.durationMinutes) min.")

    if ($null -ne $run.costUsd -and $run.costUsd -gt 0) {
        $parts += "Cost: `$$($run.costUsd)"
    }
    if ($null -ne $run.inputTokens) {
        $parts += "Input tokens: $($run.inputTokens)"
    }
    if ($null -ne $run.outputTokens) {
        $parts += "Output tokens: $($run.outputTokens)"
    }
    if ($null -ne $run.numTurns) {
        $parts += "Turns: $($run.numTurns)"
    }

    return $parts -join " | "
}
