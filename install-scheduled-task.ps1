# Install Scheduled Task for NAS Route Switcher
# Run as Administrator

$TaskName = "NAS Route Switcher"
$ScriptPath = Join-Path $PSScriptRoot "update-nas-route.ps1"
$LogFile = Join-Path $PSScriptRoot "install-log.txt"

# Start logging
Start-Transcript -Path $LogFile -Force

# Check admin privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: Run as Administrator" -ForegroundColor Red
    Stop-Transcript
    exit 1
}

Write-Host "=== Installing NAS Route Switcher Scheduled Task ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Script path: $ScriptPath" -ForegroundColor Gray

# Verify script exists
if (-not (Test-Path $ScriptPath)) {
    Write-Host "ERROR: Script not found at $ScriptPath" -ForegroundColor Red
    Stop-Transcript
    exit 1
}

# Remove existing task if present
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Removing existing task..." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# Write task XML to temp file (schtasks /create /xml is more reliable than Register-ScheduledTask)
$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Automatically switches NAS route based on network connectivity (10GbE &gt; LAN &gt; WiFi)</Description>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[EventID=10000]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[EventID=10001]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[EventID=4004]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>Queue</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <DisallowStartOnRemoteAppSession>false</DisallowStartOnRemoteAppSession>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$ScriptPath" -Silent</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$xmlPath = Join-Path $env:TEMP "nas-route-switcher-task.xml"

try {
    # Write XML to temp file with UTF-16 encoding (required by schtasks)
    $taskXml | Out-File -FilePath $xmlPath -Encoding Unicode -Force
    Write-Host "Wrote task XML to $xmlPath" -ForegroundColor Gray

    # Register using schtasks /create which handles SYSTEM principal reliably
    $result = schtasks /create /tn $TaskName /xml $xmlPath /f 2>&1
    Write-Host "schtasks output: $result" -ForegroundColor Gray

    # Clean up temp file
    Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue

    # Verify the task actually exists
    $verify = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $verify) {
        Write-Host "ERROR: Task registration reported success but task not found!" -ForegroundColor Red
        Write-Host "Trying alternative registration..." -ForegroundColor Yellow

        # Fallback: register without SYSTEM, run as current user with highest privileges
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -Silent"
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances Queue

        # Event triggers require CIM instances
        $trigger1 = New-ScheduledTaskTrigger -AtLogOn

        Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings -Trigger $trigger1 -Force | Out-Null

        # Add event triggers via CIM
        $task = Get-ScheduledTask -TaskName $TaskName
        $eventTriggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler

        $eventIds = @(10000, 10001, 4004)
        foreach ($eventId in $eventIds) {
            $subscription = "<QueryList><Query Id='0' Path='Microsoft-Windows-NetworkProfile/Operational'><Select Path='Microsoft-Windows-NetworkProfile/Operational'>*[System[EventID=$eventId]]</Select></Query></QueryList>"
            $trigger = New-CimInstance -CimClass $eventTriggerClass -ClientOnly -Property @{
                Enabled = $true
                Subscription = $subscription
            }
            $task.Triggers += $trigger
        }
        Set-ScheduledTask -InputObject $task | Out-Null

        # Verify again
        $verify = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $verify) {
            Write-Host "ERROR: Fallback registration also failed!" -ForegroundColor Red
            Stop-Transcript
            exit 1
        }
        Write-Host "Fallback registration succeeded (running as $env:USERNAME instead of SYSTEM)" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Task '$TaskName' registered successfully!" -ForegroundColor Green
    Write-Host "State: $($verify.State)" -ForegroundColor Green
    Write-Host ""
    Write-Host "Triggers:" -ForegroundColor Yellow
    Write-Host "  - Network connected (Event ID 10000)"
    Write-Host "  - Network disconnected (Event ID 10001)"
    Write-Host "  - Network state change (Event ID 4004)"
    Write-Host "  - User logon"
    Write-Host ""

    # Run it now to set initial state
    Write-Host "Running task now to set initial state..." -ForegroundColor Yellow
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 20

    # Verify it ran by checking log
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Host "Last run: $($info.LastRunTime)" -ForegroundColor Gray
    Write-Host "Last result: $($info.LastTaskResult)" -ForegroundColor Gray

    $logPath = "C:\ProgramData\NASRouteSwitcher\route-switcher.log"
    if (Test-Path $logPath) {
        Write-Host ""
        Write-Host "Recent log entries:" -ForegroundColor Yellow
        Get-Content $logPath | Select-Object -Last 5
    }
    Write-Host ""
    Write-Host "Done!" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Failed to create task: $_" -ForegroundColor Red
    Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
    Stop-Transcript
    exit 1
}

Write-Host ""
Write-Host "=== Installation Complete ===" -ForegroundColor Cyan
Stop-Transcript
