# Quick diagnostic - run as Administrator
$TaskName = "NAS Route Switcher"

Write-Host "=== Task Diagnostic ===" -ForegroundColor Cyan

# Check if task exists
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Write-Host "Task exists: YES" -ForegroundColor Green
    Write-Host "State: $($task.State)" -ForegroundColor Yellow
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Host "Last run: $($info.LastRunTime)" -ForegroundColor Yellow
    Write-Host "Last result: $($info.LastTaskResult)" -ForegroundColor Yellow
    Write-Host ""

    # Show the command it runs
    $action = $task.Actions[0]
    Write-Host "Command: $($action.Execute)" -ForegroundColor Gray
    Write-Host "Arguments: $($action.Arguments)" -ForegroundColor Gray
    Write-Host ""

    # Check if the script file exists at the path the task references
    $argsStr = $action.Arguments
    if ($argsStr -match '-File\s+"?([^"]+)"?\s') {
        $scriptPath = $Matches[1]
        Write-Host "Script path from task: $scriptPath" -ForegroundColor Gray
        Write-Host "Script file exists: $(Test-Path $scriptPath)" -ForegroundColor $(if(Test-Path $scriptPath){"Green"}else{"Red"})
    }
    Write-Host ""

    # Check log file permissions
    $logPath = "C:\ProgramData\NASRouteSwitcher\route-switcher.log"
    Write-Host "Log file exists: $(Test-Path $logPath)" -ForegroundColor Gray
    $acl = Get-Acl $logPath -ErrorAction SilentlyContinue
    if ($acl) {
        Write-Host "Log file owner: $($acl.Owner)" -ForegroundColor Gray
        $acl.Access | ForEach-Object {
            Write-Host "  $($_.IdentityReference): $($_.FileSystemRights)" -ForegroundColor Gray
        }
    }
    Write-Host ""

    # Try running it now
    Write-Host "Triggering task now..." -ForegroundColor Yellow
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Waiting 25 seconds for script to complete (15s sleep + processing)..." -ForegroundColor Yellow
    Start-Sleep -Seconds 25

    $info2 = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Host "Last run: $($info2.LastRunTime)" -ForegroundColor Yellow
    Write-Host "Last result: $($info2.LastTaskResult)" -ForegroundColor Yellow
    Write-Host ""

    Write-Host "Last 10 log lines:" -ForegroundColor Yellow
    if (Test-Path $logPath) {
        Get-Content $logPath | Select-Object -Last 10
    } else {
        Write-Host "Log file not found!" -ForegroundColor Red
    }
} else {
    Write-Host "Task exists: NO - needs reinstall!" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Cyan
Read-Host "Press Enter to close"
