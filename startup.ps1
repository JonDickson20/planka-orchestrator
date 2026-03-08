<#
.SYNOPSIS
    Starts the Planka orchestrator and dashboard on system boot.
    Registered as a Windows Scheduled Task to run at logon.
#>

$plankaDir = $PSScriptRoot
$logsDir = Join-Path $plankaDir "logs"
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

# Start the dashboard (Node.js)
$dashboardDir = Join-Path $plankaDir "dashboard"
$dashboardLog = Join-Path $logsDir "dashboard.log"
$dashboardErr = Join-Path $logsDir "dashboard-err.log"
Write-Host "Starting dashboard..."
Start-Process -FilePath "node.exe" -ArgumentList "server.js" `
    -WorkingDirectory $dashboardDir -WindowStyle Hidden `
    -RedirectStandardOutput $dashboardLog -RedirectStandardError $dashboardErr

# Start the orchestrator (PowerShell)
$orchestratorScript = Join-Path $plankaDir "planka_poll.ps1"
$orchestratorLog = Join-Path $logsDir "orchestrator.log"
$orchestratorErr = Join-Path $logsDir "orchestrator-err.log"
Write-Host "Starting orchestrator..."
Start-Process -FilePath "powershell.exe" `
    -ArgumentList "-ExecutionPolicy", "Bypass", "-File", $orchestratorScript `
    -WindowStyle Hidden `
    -RedirectStandardOutput $orchestratorLog -RedirectStandardError $orchestratorErr

Write-Host "Both services started. Dashboard: https://orchestrator.jondxn.com"
