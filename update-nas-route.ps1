# NAS Route Switcher - Automatically selects best path to NAS
# Priority: 10GbE > LAN > WiFi
# Run as Administrator (required to modify hosts file)

param(
    [switch]$Silent
)

$HostsFile = "C:\Windows\System32\drivers\etc\hosts"
$StateFile = "$env:ProgramData\NASRouteSwitcher\last-route.txt"
$NasHostnames = @("gangal-nas", "gangal-nas.local")
$Nas10GbeIP = "10.10.10.100"
$Nas1GbeIP = "192.168.1.43"

# Adapter names - adjust if yours differ
$AdapterLAN = "Ethernet"          # Killer E3100G 2.5GbE
$AdapterWiFi = "Wi-Fi"

function Write-Status($msg, $color = "White") {
    if (-not $Silent) { Write-Host $msg -ForegroundColor $color }
}

function Get-AdapterStatus($name) {
    $adapter = Get-NetAdapter -Name $name -ErrorAction SilentlyContinue
    return ($adapter -and $adapter.Status -eq "Up")
}

function Find-10GbEAdapter {
    # Find adapter by description (handles dynamic names for USB/Thunderbolt adapters)
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.InterfaceDescription -match "10G|OWC" -and $_.Status -eq "Up"
    }
    return $adapter
}

function Get-LastRoute {
    if (Test-Path $StateFile) {
        return Get-Content $StateFile -ErrorAction SilentlyContinue
    }
    return $null
}

function Save-CurrentRoute($route) {
    $stateDir = Split-Path $StateFile -Parent
    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    $route | Set-Content $StateFile -Force
}

function Show-ToastNotification($title, $message) {
    # Write toast request to file for helper script
    $toastDir = "$env:ProgramData\NASRouteSwitcher"
    if (-not (Test-Path $toastDir)) {
        New-Item -ItemType Directory -Path $toastDir -Force | Out-Null
    }

    # Create a small helper script in user-accessible location
    $helperScript = "$toastDir\show-toast.ps1"
    $helperContent = @'
param($Title, $Message)
Add-Type -AssemblyName System.Windows.Forms
$balloon = New-Object System.Windows.Forms.NotifyIcon
$balloon.Icon = [System.Drawing.SystemIcons]::Information
$balloon.BalloonTipIcon = 'Info'
$balloon.BalloonTipTitle = $Title
$balloon.BalloonTipText = $Message
$balloon.Visible = $true
$balloon.ShowBalloonTip(5000)
Start-Sleep -Seconds 6
$balloon.Dispose()
'@
    $helperContent | Set-Content $helperScript -Force

    # Find logged-in user and run toast in their context
    $sessions = query user 2>$null | Select-Object -Skip 1
    if ($sessions) {
        $activeSession = $sessions | Where-Object { $_ -match 'Active' } | Select-Object -First 1
        if ($activeSession -and $activeSession -match '^\s*>?(\S+)') {
            $userName = $Matches[1]

            # Create one-time task to show toast as the user
            $escapedTitle = $title -replace '"', '\"'
            $escapedMessage = $message -replace '"', '\"'
            $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers><TimeTrigger><StartBoundary>1900-01-01T00:00:00</StartBoundary><Enabled>false</Enabled></TimeTrigger></Triggers>
  <Principals><Principal><GroupId>S-1-5-32-545</GroupId><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>Parallel</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><ExecutionTimeLimit>PT1M</ExecutionTimeLimit><DeleteExpiredTaskAfter>PT0S</DeleteExpiredTaskAfter></Settings>
  <Actions><Exec><Command>powershell.exe</Command><Arguments>-WindowStyle Hidden -ExecutionPolicy Bypass -File "$helperScript" -Title "$escapedTitle" -Message "$escapedMessage"</Arguments></Exec></Actions>
</Task>
"@
            $taskName = "NASToast_$([guid]::NewGuid().ToString('N').Substring(0,8))"
            try {
                Register-ScheduledTask -TaskName $taskName -Xml $taskXml -Force | Out-Null
                Start-ScheduledTask -TaskName $taskName
                Start-Sleep -Seconds 1
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            } catch {
                Write-Status "Toast notification failed: $_" "Yellow"
            }
        }
    }
}

function Update-HostsFile($ip) {
    $content = Get-Content $HostsFile -ErrorAction Stop
    $newContent = @()
    $inNasBlock = $false

    foreach ($line in $content) {
        # Skip existing NAS entries
        if ($line -match "# 10GbE NAS connection") {
            $inNasBlock = $true
            continue
        }
        if ($inNasBlock -and ($line -match "gangal-nas")) {
            continue
        }
        if ($inNasBlock -and ($line -match "^\s*$" -or $line -match "^#")) {
            $inNasBlock = $false
        }
        if (-not $inNasBlock) {
            $newContent += $line
        }
    }

    # Remove trailing empty lines
    while ($newContent.Count -gt 0 -and $newContent[-1] -match "^\s*$") {
        $newContent = $newContent[0..($newContent.Count - 2)]
    }

    # Add new NAS entries
    $newContent += ""
    $newContent += "# 10GbE NAS connection (auto-managed by update-nas-route.ps1)"
    foreach ($hostname in $NasHostnames) {
        $newContent += "$ip $hostname"
    }

    $newContent | Set-Content $HostsFile -Force
}

Write-Status "=== NAS Route Switcher ===" "Cyan"
Write-Status ""

# Check adapter status
$adapter10GbE = Find-10GbEAdapter
$has10GbE = $null -ne $adapter10GbE
$hasLAN = Get-AdapterStatus $AdapterLAN
$hasWiFi = Get-AdapterStatus $AdapterWiFi

Write-Status "Network Status:" "Yellow"
$10GbEName = if ($has10GbE) { $adapter10GbE.Name } else { "not connected" }
Write-Status "  10GbE ($10GbEName): $(if($has10GbE){'UP'}else{'DOWN'})" $(if($has10GbE){"Green"}else{"Gray"})
Write-Status "  LAN ($AdapterLAN): $(if($hasLAN){'UP'}else{'DOWN'})" $(if($hasLAN){"Green"}else{"Gray"})
Write-Status "  WiFi ($AdapterWiFi): $(if($hasWiFi){'UP'}else{'DOWN'})" $(if($hasWiFi){"Green"}else{"Gray"})
Write-Status ""

# Determine best route
if ($has10GbE) {
    $selectedIP = $Nas10GbeIP
    $selectedRoute = "10GbE Direct"
} elseif ($hasLAN -or $hasWiFi) {
    $selectedIP = $Nas1GbeIP
    $selectedRoute = if ($hasLAN) { "LAN (1GbE)" } else { "WiFi" }
} else {
    Write-Status "ERROR: No network adapters connected!" "Red"
    exit 1
}

Write-Status "Selected Route: $selectedRoute" "Green"
Write-Status "NAS IP: $selectedIP" "Green"
Write-Status ""

# Check admin privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Status "ERROR: Run as Administrator to modify hosts file" "Red"
    exit 1
}

# Check if route changed
$lastRoute = Get-LastRoute
$routeChanged = ($lastRoute -ne $selectedRoute)

# Update hosts file
try {
    Update-HostsFile $selectedIP
    Write-Status "Hosts file updated successfully" "Green"

    # Flush DNS cache
    ipconfig /flushdns | Out-Null
    Write-Status "DNS cache flushed" "Green"

    # Save current route
    Save-CurrentRoute $selectedRoute
} catch {
    Write-Status "ERROR: Failed to update hosts file: $_" "Red"
    exit 1
}

Write-Status ""

# Verify connectivity
Write-Status "Testing connectivity..." "Yellow"
$ping = Test-Connection -ComputerName $selectedIP -Count 1 -ErrorAction SilentlyContinue
if ($ping) {
    Write-Status "NAS is reachable at $selectedIP" "Green"
} else {
    Write-Status "WARNING: NAS not responding at $selectedIP" "Red"
}

# Show toast notification if route changed
if ($routeChanged) {
    Write-Status ""
    Write-Status "Route changed from '$lastRoute' to '$selectedRoute' - showing notification" "Yellow"

    $icon = if ($selectedRoute -eq "10GbE Direct") { "⚡" } else { "🌐" }
    $speed = if ($selectedRoute -eq "10GbE Direct") { "10 Gbps" } elseif ($selectedRoute -eq "LAN (1GbE)") { "1 Gbps" } else { "WiFi" }

    Show-ToastNotification "NAS Route: $selectedRoute" "Gangal-NAS now connected via $speed ($selectedIP)"
}

Write-Status ""
Write-Status "=== Done ===" "Cyan"
