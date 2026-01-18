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

# Remove existing task if present
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Removing existing task..." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# Create XML for the task (more reliable for event triggers)
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
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
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
      <Arguments>-ExecutionPolicy Bypass -WindowStyle Hidden -File "$ScriptPath" -Silent</Arguments>
    </Exec>
  </Actions>
</Task>
"@

try {
    # Register task from XML
    Register-ScheduledTask -TaskName $TaskName -Xml $taskXml -Force | Out-Null

    Write-Host "Task '$TaskName' created successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Triggers:" -ForegroundColor Yellow
    Write-Host "  - Network connected (Event ID 10000)"
    Write-Host "  - Network disconnected (Event ID 10001)"
    Write-Host "  - Network state change (Event ID 4004)"
    Write-Host "  - User logon"
    Write-Host ""
    Write-Host "The task runs as SYSTEM with highest privileges." -ForegroundColor Gray
    Write-Host ""

    # Run it now to set initial state
    Write-Host "Running task now to set initial state..." -ForegroundColor Yellow
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 3

    # Verify it ran
    $lastRun = (Get-ScheduledTaskInfo -TaskName $TaskName).LastRunTime
    Write-Host "Last run: $lastRun" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Done!" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Failed to create task: $_" -ForegroundColor Red
    Stop-Transcript
    exit 1
}

Write-Host ""
Write-Host "=== Installation Complete ===" -ForegroundColor Cyan
Stop-Transcript
