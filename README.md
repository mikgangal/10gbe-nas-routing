# 10GbE NAS Routing Configuration

**Date:** 2026-01-17
**Status:** Working - auto-routing script added

## Overview

Configured PC to route traffic to Synology NAS (Gangal-NAS) over the 10GbE direct connection instead of through the 1GbE LAN.

## Auto-Routing Script

The `update-nas-route.ps1` script automatically selects the best path to the NAS based on available networks.

**Priority:** 10GbE (direct) > LAN (1GbE) > WiFi

### Usage

Run as Administrator:
```
.\update-nas-route.bat
```
Or from PowerShell (Admin):
```powershell
.\update-nas-route.ps1
```

### What it does

1. Detects which network adapters are connected
2. Selects the best route based on priority
3. Updates the hosts file to point `gangal-nas` to the correct IP
4. Flushes DNS cache
5. Verifies NAS connectivity

### NAS IP Addresses

| Connection | IP Address |
|------------|------------|
| 10GbE Direct | 10.10.10.100 |
| LAN/WiFi (1GbE) | 192.168.1.43 |

### Automatic Mode (Scheduled Task)

To run automatically on network changes:
```
.\install-scheduled-task.bat
```

This creates a scheduled task that triggers on:
- Network connected (Event ID 10000)
- Network disconnected (Event ID 10001)
- User logon

To remove:
```powershell
.\uninstall-scheduled-task.ps1
```

## Hardware

| Device | Adapter | IP Address | Subnet |
|--------|---------|------------|--------|
| PC | OWC 10Gbit Network Adapter | 10.10.10.101 | 255.255.0.0 (/16) |
| PC | Killer E3100G 2.5GbE | 192.168.1.22 | 255.255.255.0 (/24) |
| NAS | 10GbE interface | 10.10.10.100 | 255.255.0.0 (/16) |

## Changes Made

### 1. PC Subnet Mask (Changed)
- **Before:** 10.10.10.101/24 (255.255.255.0)
- **After:** 10.10.10.101/16 (255.255.0.0)
- **Reason:** Match NAS subnet configuration

### 2. NAS Gateway (User Changed on NAS)
- **Before:** 10.10.10.1 (non-existent)
- **After:** 10.10.10.101 (PC's 10GbE IP)
- **Reason:** 10.10.10.1 didn't exist, causing routing issues

### 3. Hosts File Entry (Added)
Location: `C:\Windows\System32\drivers\etc\hosts`
```
# 10GbE NAS connection
10.10.10.100 gangal-nas
10.10.10.100 gangal-nas.local
```
- **Reason:** Force `gangal-nas` hostname to resolve to 10GbE IP instead of mDNS (which resolved to 1GbE IPv6)

## Speed Test Results

| Direction | Speed | Bandwidth |
|-----------|-------|-----------|
| Write | 197 MB/s | 1.58 Gbps |
| Read | 894 MB/s | 7.15 Gbps |

Read speed is excellent. Write speed limited by NAS disk/RAID, not network.

## Known Issues

### OWC 10GbE Adapter Resets
Event log showed adapter reset on 12/24/2025:
> "The network interface 'OWC 10Gbit Network Adapter' has begun resetting. The network driver detected that its hardware has stopped responding to commands."

**Recommendation:** Update OWC 10GbE drivers if issues persist.

### High Discarded Packet Count
The 10GbE adapter showed ~8.5 billion discarded packets. This may indicate past connectivity issues or driver problems.

## Pending Actions

1. **Reboot PC** - Required to reset SMB client (currently showing "binding handle invalid" error)
2. After reboot, verify `\\gangal-nas` connects via 10GbE
3. Remap Z: drive if needed:
   ```
   net use Z: \\gangal-nas\ssd-m.2 /persistent:yes
   ```

## Verification Commands

```batch
# Check 10GbE link speed
powershell -Command "Get-NetAdapter -Name 'Ethernet 2' | Select-Object Name, LinkSpeed, Status"

# Verify gangal-nas resolves to 10GbE IP
ping gangal-nas -n 1

# Check routing table
route print | findstr 10.10

# Test SMB connectivity
net view \\gangal-nas

# Check which interface is used for NAS traffic
powershell -Command "Test-NetConnection 10.10.10.100 -Port 445 | Select-Object InterfaceAlias, SourceAddress"
```

## Rollback Instructions

If issues occur, revert changes:

### Remove hosts entry
Edit `C:\Windows\System32\drivers\etc\hosts` and remove:
```
# 10GbE NAS connection
10.10.10.100 gangal-nas
10.10.10.100 gangal-nas.local
```

### Reset PC IP to /24
```powershell
# Run as Administrator
Remove-NetIPAddress -InterfaceAlias 'Ethernet 2' -IPAddress 10.10.10.101 -Confirm:$false
New-NetIPAddress -InterfaceAlias 'Ethernet 2' -IPAddress 10.10.10.101 -PrefixLength 24
```

### NAS Gateway
Set NAS 10GbE gateway back to blank or original value.
