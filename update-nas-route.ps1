# NAS Route Switcher - Automatically selects best path to NAS
# Priority: 10GbE > LAN > WiFi
# Run as Administrator (required to modify hosts file)

param(
    [switch]$Silent
)

$HostsFile = "C:\Windows\System32\drivers\etc\hosts"
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

# Update hosts file
try {
    Update-HostsFile $selectedIP
    Write-Status "Hosts file updated successfully" "Green"

    # Flush DNS cache
    ipconfig /flushdns | Out-Null
    Write-Status "DNS cache flushed" "Green"
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

Write-Status ""
Write-Status "=== Done ===" "Cyan"
