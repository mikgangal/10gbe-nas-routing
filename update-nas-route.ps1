# NAS Route Switcher - Automatically selects best path to NAS
# Priority: 10GbE > LAN > WiFi
# Run as Administrator (required to modify hosts file)

param(
    [switch]$Silent
)

$HostsFile = "C:\Windows\System32\drivers\etc\hosts"
$DataDir = "C:\ProgramData\NASRouteSwitcher"
$StateFile = "$DataDir\last-route.txt"
$LogFile = "$DataDir\route-switcher.log"

# Ensure data directory exists
if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
}

# Immediate log to confirm script started
Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Script starting..." -ErrorAction SilentlyContinue

# Wait for network state to stabilize after event trigger
Start-Sleep -Seconds 3
Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Waited 3 seconds for network state to stabilize" -ErrorAction SilentlyContinue

function Write-Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] $msg"
    Add-Content -Path $LogFile -Value $logLine -ErrorAction SilentlyContinue
}
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

function Reset-SmbConnections {
    Write-Status "Resetting SMB connections to NAS..." "Yellow"

    # Close all SMB connections to the NAS
    foreach ($hostname in $NasHostnames) {
        net use "\\$hostname" /delete /y 2>$null | Out-Null
    }

    # Also close connections by IP
    net use "\\$Nas10GbeIP" /delete /y 2>$null | Out-Null
    net use "\\$Nas1GbeIP" /delete /y 2>$null | Out-Null

    # Remove any SMB mappings (like Z: drive)
    Get-SmbMapping -ErrorAction SilentlyContinue | Where-Object {
        $_.RemotePath -match "gangal-nas|$Nas10GbeIP|$Nas1GbeIP"
    } | ForEach-Object {
        Remove-SmbMapping -RemotePath $_.RemotePath -Force -ErrorAction SilentlyContinue
    }

    # Close SMB sessions
    Get-SmbSession -ErrorAction SilentlyContinue | Where-Object {
        $_.ClientComputerName -match "gangal-nas|$Nas10GbeIP|$Nas1GbeIP"
    } | Close-SmbSession -Force -ErrorAction SilentlyContinue

    Write-Status "SMB connections reset" "Green"
}

function Show-ToastNotification($title, $message) {
    $toastDir = "$DataDir"

    # Create VBScript for silent notification (no console window)
    $vbsScript = "$toastDir\show-toast.vbs"
    @"
Set objShell = CreateObject("WScript.Shell")
objShell.Popup "$message", 5, "$title", 64
"@ | Set-Content $vbsScript -Force

    # Run VBScript as interactive user via scheduled task
    try {
        $taskName = "NASToast_$((Get-Random).ToString())"
        $action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbsScript`""
        $principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users" -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 1)

        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 1
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    } catch {
        Write-Status "Toast notification failed: $_" "Yellow"
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

Write-Log "========== Script started =========="
Write-Status "=== NAS Route Switcher ===" "Cyan"
Write-Status ""

# Check adapter status
Write-Log "Checking network adapters..."
$adapter10GbE = Find-10GbEAdapter
$has10GbE = $null -ne $adapter10GbE
$hasLAN = Get-AdapterStatus $AdapterLAN
$hasWiFi = Get-AdapterStatus $AdapterWiFi

$10GbEName = if ($has10GbE) { $adapter10GbE.Name } else { "not connected" }
Write-Log "10GbE ($10GbEName): $(if($has10GbE){'UP'}else{'DOWN'})"
Write-Log "LAN ($AdapterLAN): $(if($hasLAN){'UP'}else{'DOWN'})"
Write-Log "WiFi ($AdapterWiFi): $(if($hasWiFi){'UP'}else{'DOWN'})"

Write-Status "Network Status:" "Yellow"
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
    Write-Log "ERROR: No network adapters connected"
    Write-Status "ERROR: No network adapters connected!" "Red"
    exit 1
}

Write-Log "Selected route: $selectedRoute ($selectedIP)"
Write-Status "Selected Route: $selectedRoute" "Green"
Write-Status "NAS IP: $selectedIP" "Green"
Write-Status ""

# Check admin privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Log "ERROR: Not running as admin"
    Write-Status "ERROR: Run as Administrator to modify hosts file" "Red"
    exit 1
}
Write-Log "Running as admin: OK"

# Check if route changed
$lastRoute = Get-LastRoute
$routeChanged = ($lastRoute -ne $selectedRoute)
Write-Log "Last route: '$lastRoute' | New route: '$selectedRoute' | Changed: $routeChanged"

# If route changed, reset SMB connections first (prevents hanging)
if ($routeChanged -and $lastRoute) {
    Write-Log "Route changed - resetting SMB connections..."
    Reset-SmbConnections
    Write-Log "SMB reset complete"
}

# Update hosts file
try {
    Write-Log "Updating hosts file..."
    Update-HostsFile $selectedIP
    Write-Status "Hosts file updated successfully" "Green"
    Write-Log "Hosts file updated"

    # Flush DNS cache
    Write-Log "Flushing DNS cache..."
    ipconfig /flushdns | Out-Null
    Write-Status "DNS cache flushed" "Green"
    Write-Log "DNS cache flushed"

    # Save current route
    Save-CurrentRoute $selectedRoute
    Write-Log "Route state saved"
} catch {
    Write-Log "ERROR: Failed to update hosts file: $_"
    Write-Status "ERROR: Failed to update hosts file: $_" "Red"
    exit 1
}

Write-Status ""

# Verify connectivity
Write-Status "Testing connectivity..." "Yellow"
Write-Log "Testing connectivity to $selectedIP..."
$ping = Test-Connection -ComputerName $selectedIP -Count 1 -ErrorAction SilentlyContinue
if ($ping) {
    Write-Status "NAS is reachable at $selectedIP" "Green"
    Write-Log "Ping to $selectedIP - SUCCESS"
} else {
    Write-Status "WARNING: NAS not responding at $selectedIP" "Red"
    Write-Log "Ping to $selectedIP - FAILED"
}

# Show toast notification if route changed
if ($routeChanged) {
    Write-Status ""
    Write-Status "Route changed from '$lastRoute' to '$selectedRoute' - showing notification" "Yellow"
    Write-Log "Showing toast notification..."

    $icon = if ($selectedRoute -eq "10GbE Direct") { "⚡" } else { "🌐" }
    $speed = if ($selectedRoute -eq "10GbE Direct") { "10 Gbps" } elseif ($selectedRoute -eq "LAN (1GbE)") { "1 Gbps" } else { "WiFi" }

    Show-ToastNotification "NAS Route: $selectedRoute" "Gangal-NAS now connected via $speed ($selectedIP)"
    Write-Log "Toast notification triggered"
}

Write-Log "========== Script completed =========="
Write-Status ""
Write-Status "=== Done ===" "Cyan"
