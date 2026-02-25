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
$AdapterDownMarker = "$DataDir\adapter-down.marker"

# Ensure data directory exists
if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
}

# Log rotation: if log exceeds 100KB, rotate to .log.old
if (Test-Path $LogFile) {
    $logSize = (Get-Item $LogFile -ErrorAction SilentlyContinue).Length
    if ($logSize -gt 102400) {
        Move-Item -Path $LogFile -Destination "$LogFile.old" -Force -ErrorAction SilentlyContinue
    }
}

# Immediate log to confirm script started
Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Script starting..." -ErrorAction SilentlyContinue

# Wait for network state to stabilize after event trigger
# Thunderbolt daisy-chain re-enumeration can take 15-30s, so we wait longer
Start-Sleep -Seconds 15
Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Waited 15 seconds for network state to stabilize" -ErrorAction SilentlyContinue

function Write-Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] $msg"
    Add-Content -Path $LogFile -Value $logLine -ErrorAction SilentlyContinue
}

# Load configuration from config.json (next to this script), fall back to defaults
$configPath = Join-Path $PSScriptRoot "config.json"
$config = $null
if (Test-Path $configPath) {
    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        Write-Log "Loaded config from $configPath"
    } catch {
        Write-Log "WARNING: Failed to parse config.json, using defaults: $_"
    }
}

$NasHostnames      = if ($config.NasHostnames)      { @($config.NasHostnames) }    else { @("gangal-nas", "gangal-nas.local") }
$Nas10GbeIP        = if ($config.Nas10GbeIP)         { $config.Nas10GbeIP }         else { "10.10.10.100" }
$Nas1GbeIP         = if ($config.Nas1GbeIP)          { $config.Nas1GbeIP }          else { "192.168.1.43" }
$Pc10GbeIP         = if ($config.Pc10GbeIP)          { $config.Pc10GbeIP }          else { "10.10.10.1" }
$Pc10GbeSubnet     = if ($config.Pc10GbeSubnet)      { [int]$config.Pc10GbeSubnet } else { 24 }
$Adapter10GbEMatch = if ($config.Adapter10GbEMatch)  { $config.Adapter10GbEMatch }  else { "10G|OWC" }

function Write-Status($msg, $color = "White") {
    if (-not $Silent) { Write-Host $msg -ForegroundColor $color }
}

function Find-10GbEAdapter {
    # Find adapter by description (handles dynamic names for USB/Thunderbolt adapters)
    # Match pattern is configurable via config.json (Adapter10GbEMatch)
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.InterfaceDescription -match $Adapter10GbEMatch -and $_.Status -eq "Up"
    }
    return $adapter
}

function Find-LANAdapter($exclude10GbE) {
    # Find any UP physical (non-virtual) ethernet adapter that isn't the 10GbE
    # Works regardless of adapter name — detects Realtek USB GbE, Killer E3100G, etc.
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.Status -eq "Up" -and
        $_.Virtual -eq $false -and
        $_.ConnectorPresent -eq $true -and
        $_.MediaType -eq "802.3" -and
        (-not $exclude10GbE -or $_.InterfaceDescription -notmatch $Adapter10GbEMatch)
    } | Sort-Object LinkSpeed -Descending | Select-Object -First 1
    return $adapter
}

function Find-WiFiAdapter {
    # Find any UP wireless adapter
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.Status -eq "Up" -and
        $_.MediaType -match "802\.11|Native"
    } | Select-Object -First 1
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

    # Restart SMB client service to force-close persistent TCP connections
    # net use /delete and Close-SmbSession don't kill connections held by open apps (File Explorer)
    Write-Log "Restarting LanmanWorkstation service to force-close persistent connections..."
    Restart-Service LanmanWorkstation -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    Write-Status "SMB connections reset" "Green"
}

function Set-NasRouteBlock($selectedRoute) {
    # Block the NAS IP we DON'T want to use by adding a null route (IF 1 = loopback).
    # This prevents Windows from reconnecting SMB via the wrong path.
    # When on 10GbE: block 192.168.1.43 (force traffic to 10.10.10.100)
    # When on LAN:   remove the block (allow 192.168.1.43), block 10.10.10.100 isn't needed since adapter is down
    if ($selectedRoute -eq "10GbE Direct") {
        # Block NAS 1GbE IP
        route delete $Nas1GbeIP 2>$null | Out-Null
        route add $Nas1GbeIP mask 255.255.255.255 0.0.0.0 IF 1 2>$null | Out-Null
        Write-Log "Blocked route to $Nas1GbeIP (force 10GbE path)"
    } else {
        # Remove block on NAS 1GbE IP
        route delete $Nas1GbeIP 2>$null | Out-Null
        Write-Log "Unblocked route to $Nas1GbeIP (LAN/WiFi fallback)"
    }
}

function Set-LANIPv6State($adapter, [bool]$enabled) {
    # When 10GbE is active, disable IPv6 on the LAN adapter to prevent
    # Windows SMB from using IPv6 link-local on the slower path.
    # Re-enable when falling back to LAN.
    if (-not $adapter) { return }
    $binding = Get-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
    if (-not $binding) { return }
    if ($enabled -and -not $binding.Enabled) {
        Enable-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
        Write-Log "Re-enabled IPv6 on $($adapter.Name) (LAN fallback)"
    } elseif (-not $enabled -and $binding.Enabled) {
        Disable-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
        Write-Log "Disabled IPv6 on $($adapter.Name) (10GbE active - prevent SMB wrong path)"
    }
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

function Ensure-10GbEStaticIP($adapter) {
    # Check if the 10GbE adapter has an IP on the correct subnet, auto-assign if not
    $targetSubnet = ($Pc10GbeIP -replace "\.\d+$", ".")  # e.g. "10.10.10."
    $currentIPs = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue

    $hasCorrectIP = $false
    foreach ($ip in $currentIPs) {
        if ($ip.IPAddress.StartsWith($targetSubnet)) {
            $hasCorrectIP = $true
            Write-Log "10GbE adapter already has correct IP: $($ip.IPAddress)/$($ip.PrefixLength)"
            break
        }
    }

    if (-not $hasCorrectIP) {
        $currentAddr = if ($currentIPs) { ($currentIPs | Select-Object -First 1).IPAddress } else { "none" }
        Write-Log "10GbE adapter IP is '$currentAddr' - not on ${targetSubnet}x subnet, assigning ${Pc10GbeIP}/${Pc10GbeSubnet}"
        Write-Status "Configuring 10GbE IP: $Pc10GbeIP/$Pc10GbeSubnet..." "Yellow"

        # Remove existing IPv4 addresses on this adapter
        $currentIPs | ForEach-Object {
            Remove-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $_.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
        }

        try {
            New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $Pc10GbeIP -PrefixLength $Pc10GbeSubnet -ErrorAction Stop | Out-Null
            Write-Log "Assigned static IP $Pc10GbeIP/$Pc10GbeSubnet to $($adapter.Name)"
            Write-Status "10GbE IP configured: $Pc10GbeIP" "Green"

            # Brief wait for IP to take effect
            Start-Sleep -Seconds 2
        } catch {
            Write-Log "ERROR: Failed to assign static IP: $_"
            Write-Status "ERROR: Failed to configure 10GbE IP: $_" "Red"
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
    while ($newContent.Count -gt 1 -and $newContent[-1] -match "^\s*$") {
        $newContent = $newContent[0..($newContent.Count - 2)]
    }
    # Handle edge case: single empty element
    if ($newContent.Count -eq 1 -and $newContent[0] -match "^\s*$") {
        $newContent = @()
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

# Check adapter status with retry for 10GbE
# Thunderbolt daisy-chain devices can take time to enumerate after connect events,
# so if 10GbE was previously active and now appears down, retry before switching away
Write-Log "Checking network adapters..."
$adapter10GbE = Find-10GbEAdapter
$has10GbE = $null -ne $adapter10GbE
$adapterLANFound = Find-LANAdapter -exclude10GbE $true
$hasLAN = $null -ne $adapterLANFound
$adapterWiFiFound = Find-WiFiAdapter
$hasWiFi = $null -ne $adapterWiFiFound

# Debounce: if 10GbE is down but was our last route, retry up to 3 times
# This prevents premature fallback during Thunderbolt re-enumeration
$lastRoute = Get-LastRoute
$10GbERecovered = $false
if (-not $has10GbE -and $lastRoute -eq "10GbE Direct") {
    $retryCount = 3
    $retryDelay = 10
    Write-Log "10GbE down but was last active route - retrying ($retryCount attempts, ${retryDelay}s apart)..."
    Write-Status "10GbE not detected, retrying (was previously connected)..." "Yellow"
    for ($i = 1; $i -le $retryCount; $i++) {
        Start-Sleep -Seconds $retryDelay
        $adapter10GbE = Find-10GbEAdapter
        $has10GbE = $null -ne $adapter10GbE
        Write-Log "  Retry ${i}/${retryCount}: 10GbE $(if($has10GbE){'FOUND'}else{'still down'})"
        if ($has10GbE) {
            # 10GbE was down and came back — SMB sessions are likely stale
            $10GbERecovered = $true
            Write-Log "10GbE recovered after being down - will force SMB reset"
            break
        }
    }
    # Re-check LAN/WiFi after debounce period (they may have come up)
    if (-not $has10GbE) {
        $adapterLANFound = Find-LANAdapter -exclude10GbE $true
        $hasLAN = $null -ne $adapterLANFound
        $adapterWiFiFound = Find-WiFiAdapter
        $hasWiFi = $null -ne $adapterWiFiFound
    }
}

$10GbEName = if ($has10GbE) { $adapter10GbE.Name } else { "not connected" }
$lanName = if ($hasLAN) { "$($adapterLANFound.Name) ($($adapterLANFound.InterfaceDescription))" } else { "none found" }
$wifiName = if ($hasWiFi) { "$($adapterWiFiFound.Name)" } else { "none found" }
Write-Log "10GbE ($10GbEName): $(if($has10GbE){'UP'}else{'DOWN'})"
Write-Log "LAN ($lanName): $(if($hasLAN){'UP'}else{'DOWN'})"
Write-Log "WiFi ($wifiName): $(if($hasWiFi){'UP'}else{'DOWN'})"

Write-Status "Network Status:" "Yellow"
Write-Status "  10GbE ($10GbEName): $(if($has10GbE){'UP'}else{'DOWN'})" $(if($has10GbE){"Green"}else{"Gray"})
Write-Status "  LAN ($lanName): $(if($hasLAN){'UP'}else{'DOWN'})" $(if($hasLAN){"Green"}else{"Gray"})
Write-Status "  WiFi ($wifiName): $(if($hasWiFi){'UP'}else{'DOWN'})" $(if($hasWiFi){"Green"}else{"Gray"})
Write-Status ""

# Determine best route
if ($has10GbE) {
    $selectedIP = $Nas10GbeIP
    $selectedRoute = "10GbE Direct"
} elseif ($hasLAN -or $hasWiFi) {
    $selectedIP = $Nas1GbeIP
    $selectedRoute = if ($hasLAN) { "LAN (1GbE)" } else { "WiFi" }
} else {
    # All adapters down - likely Thunderbolt dock disconnect
    # Write marker so reconnection knows to reset SMB sessions
    Get-Date -Format "yyyy-MM-dd HH:mm:ss" | Set-Content $AdapterDownMarker -Force
    Write-Log "All adapters down - wrote adapter-down marker, polling for recovery..."
    Write-Status "All adapters down, waiting for reconnection..." "Yellow"

    # Poll for any adapter to come back (up to 60s)
    $pollInterval = 5
    $maxPollTime = 60
    $elapsed = 0
    while ($elapsed -lt $maxPollTime) {
        Start-Sleep -Seconds $pollInterval
        $elapsed += $pollInterval
        $adapter10GbE = Find-10GbEAdapter
        $has10GbE = $null -ne $adapter10GbE
        $adapterLANFound = Find-LANAdapter -exclude10GbE $true
        $hasLAN = $null -ne $adapterLANFound
        $adapterWiFiFound = Find-WiFiAdapter
        $hasWiFi = $null -ne $adapterWiFiFound
        if ($has10GbE -or $hasLAN -or $hasWiFi) {
            Write-Log "Adapter recovered after ${elapsed}s - 10GbE:$(if($has10GbE){'UP'}else{'DOWN'}) LAN:$(if($hasLAN){'UP'}else{'DOWN'}) WiFi:$(if($hasWiFi){'UP'}else{'DOWN'})"
            break
        }
        Write-Log "  Poll ${elapsed}s/${maxPollTime}s: still no adapters"
    }

    # Re-evaluate after polling
    if ($has10GbE) {
        $selectedIP = $Nas10GbeIP
        $selectedRoute = "10GbE Direct"
    } elseif ($hasLAN -or $hasWiFi) {
        $selectedIP = $Nas1GbeIP
        $selectedRoute = if ($hasLAN) { "LAN (1GbE)" } else { "WiFi" }
    } else {
        Write-Log "ERROR: No adapters recovered after ${maxPollTime}s - giving up"
        Write-Status "ERROR: No network adapters connected after waiting!" "Red"
        exit 1
    }
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

# Check if route changed (lastRoute already fetched above for debounce logic)
if (-not $lastRoute) { $lastRoute = Get-LastRoute }
$routeChanged = ($lastRoute -ne $selectedRoute)
$wasAdapterDown = Test-Path $AdapterDownMarker
$needsSmbReset = $routeChanged -or $wasAdapterDown -or $10GbERecovered
Write-Log "Last route: '$lastRoute' | New route: '$selectedRoute' | Changed: $routeChanged | Recovering from down: $wasAdapterDown | 10GbE recovered: $10GbERecovered"

# Manage network path isolation to prevent SMB using wrong adapter
# When 10GbE is active: disable IPv6 on LAN + block NAS 1GbE IP (force all traffic via 10GbE)
# When falling back to LAN: re-enable IPv6 + unblock NAS 1GbE IP
if ($selectedRoute -eq "10GbE Direct") {
    Set-LANIPv6State $adapterLANFound $false
} else {
    Set-LANIPv6State $adapterLANFound $true
}
Set-NasRouteBlock $selectedRoute

# Reset SMB if route changed, recovering from adapter-down, or 10GbE was down and came back
# When a Thunderbolt dock is hot-reconnected to the same route, SMB sessions
# from before the disconnect are stale and will hang unless cleared
if (($routeChanged -and $lastRoute) -or $wasAdapterDown -or $10GbERecovered) {
    $reason = if ($10GbERecovered) { "10GbE reconnection" } elseif ($wasAdapterDown) { "adapter recovery" } else { "route change" }
    Write-Log "Resetting SMB connections (reason: $reason)..."
    Reset-SmbConnections
    Write-Log "SMB reset complete"

    # Clear the adapter-down marker now that we've recovered
    if ($wasAdapterDown) {
        Remove-Item $AdapterDownMarker -Force -ErrorAction SilentlyContinue
        Write-Log "Cleared adapter-down marker"
    }
}

# Auto-configure 10GbE static IP if needed
if ($selectedRoute -eq "10GbE Direct" -and $adapter10GbE) {
    Ensure-10GbEStaticIP $adapter10GbE
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
    Write-Log "Ping to $selectedIP - FAILED, diagnosing..."

    # Diagnose: check if the adapter has the right IP
    if ($selectedRoute -eq "10GbE Direct" -and $adapter10GbE) {
        $adapterIPs = Get-NetIPAddress -InterfaceIndex $adapter10GbE.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $ipList = ($adapterIPs | ForEach-Object { $_.IPAddress }) -join ", "
        Write-Log "10GbE adapter IPs: $ipList"

        $targetSubnet = ($Pc10GbeIP -replace "\.\d+$", ".")
        $onCorrectSubnet = $adapterIPs | Where-Object { $_.IPAddress.StartsWith($targetSubnet) }

        if (-not $onCorrectSubnet) {
            Write-Log "10GbE adapter not on ${targetSubnet}x subnet - attempting IP fix..."
            Write-Status "10GbE IP misconfigured, attempting fix..." "Yellow"
            Ensure-10GbEStaticIP $adapter10GbE

            # Retry ping after fix
            $ping2 = Test-Connection -ComputerName $selectedIP -Count 2 -ErrorAction SilentlyContinue
            if ($ping2) {
                Write-Status "NAS is reachable at $selectedIP (after IP fix)" "Green"
                Write-Log "Ping to $selectedIP after IP fix - SUCCESS"
            } else {
                Write-Status "WARNING: NAS still not responding at $selectedIP after IP fix" "Red"
                Write-Log "Ping to $selectedIP after IP fix - STILL FAILED"
            }
        } else {
            Write-Status "WARNING: NAS not responding at $selectedIP (IP config looks correct: $ipList)" "Red"
            Write-Log "IP config looks correct ($ipList) but NAS not responding - may be a NAS-side issue"
        }
    } else {
        Write-Status "WARNING: NAS not responding at $selectedIP" "Red"
        Write-Log "Ping to $selectedIP - FAILED (non-10GbE route, no auto-fix available)"
    }
}

# Show toast notification if route changed or recovered
if ($needsSmbReset) {
    Write-Status ""
    $notifyReason = if ($10GbERecovered -or ($wasAdapterDown -and -not $routeChanged)) { "reconnected" } else { "changed" }
    Write-Status "Route $notifyReason - '$lastRoute' -> '$selectedRoute' - showing notification" "Yellow"
    Write-Log "Showing toast notification (reason: $notifyReason)..."

    $icon = if ($selectedRoute -eq "10GbE Direct") { "⚡" } else { "🌐" }
    $speed = if ($selectedRoute -eq "10GbE Direct") { "10 Gbps" } elseif ($selectedRoute -eq "LAN (1GbE)") { "1 Gbps" } else { "WiFi" }
    $toastMsg = if ($10GbERecovered -or ($wasAdapterDown -and -not $routeChanged)) {
        "Gangal-NAS reconnected via $speed ($selectedIP)"
    } else {
        "Gangal-NAS now connected via $speed ($selectedIP)"
    }

    Show-ToastNotification "NAS Route: $selectedRoute" $toastMsg
    Write-Log "Toast notification triggered"
}

Write-Log "========== Script completed =========="
Write-Status ""
Write-Status "=== Done ===" "Cyan"
