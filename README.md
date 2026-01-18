# 10GbE NAS Auto-Routing for Windows

Automatically switches NAS hostname resolution between 10GbE direct connection and 1GbE LAN/WiFi based on network availability.

## Features

- **Auto-detection**: Monitors network connect/disconnect events
- **Priority routing**: 10GbE > LAN > WiFi
- **SMB session reset**: Prevents File Explorer hanging when switching networks
- **Popup notifications**: Shows route changes without console window flash
- **Persists across reboots**: Runs as a Windows scheduled task
- **Logging**: Full activity log for troubleshooting

## Quick Start

### Install (one-time setup)

Run as Administrator:
```
.\install-scheduled-task.bat
```

That's it! The script will now run automatically when:
- Network connects (Event ID 10000)
- Network disconnects (Event ID 10001)
- Network state changes (Event ID 4004)
- User logs in

### Uninstall

```powershell
.\uninstall-scheduled-task.ps1
```

### Manual Run

If needed, run manually as Administrator:
```
.\update-nas-route.bat
```

## How It Works

1. Detects which network adapters are connected
2. Selects the best route based on priority:
   - **10GbE Direct** → `10.10.10.100`
   - **LAN (1GbE)** → `192.168.1.43`
   - **WiFi** → `192.168.1.43`
3. Resets SMB connections (prevents stale session hangs)
4. Updates the Windows hosts file
5. Flushes DNS cache
6. Shows popup notification if route changed

## Configuration

Edit `update-nas-route.ps1` to customize:

```powershell
# NAS IP addresses
$Nas10GbeIP = "10.10.10.100"    # NAS 10GbE interface
$Nas1GbeIP = "192.168.1.43"     # NAS 1GbE interface

# Adapter names (run Get-NetAdapter to find yours)
$AdapterLAN = "Ethernet"        # Your LAN adapter name
$AdapterWiFi = "Wi-Fi"          # Your WiFi adapter name
```

## Files

| File | Description |
|------|-------------|
| `update-nas-route.ps1` | Main routing script |
| `update-nas-route.bat` | Run script as admin (manual) |
| `install-scheduled-task.ps1` | Install automatic triggers |
| `install-scheduled-task.bat` | Run installer as admin |
| `uninstall-scheduled-task.ps1` | Remove scheduled task |
| `verify-config.ps1` | Verify network configuration |
| `remap-drive.bat` | Remap Z: drive to NAS |

## Logs & State

Located in `C:\ProgramData\NASRouteSwitcher\`:

| File | Description |
|------|-------------|
| `route-switcher.log` | Activity log with timestamps |
| `last-route.txt` | Current route state |
| `show-toast.vbs` | Notification helper |

## Hardware Setup

| Device | Adapter | IP Address | Subnet |
|--------|---------|------------|--------|
| PC | OWC 10GbE | 10.10.10.101 | /16 |
| PC | Killer E3100G 2.5GbE | 192.168.1.x | /24 |
| NAS | 10GbE interface | 10.10.10.100 | /16 |
| NAS | 1GbE interface | 192.168.1.43 | /24 |

## Speed Test Results

| Direction | Speed | Bandwidth |
|-----------|-------|-----------|
| Read | 894 MB/s | 7.15 Gbps |
| Write | 197 MB/s | 1.58 Gbps |

## Troubleshooting

### Check the log
```powershell
Get-Content C:\ProgramData\NASRouteSwitcher\route-switcher.log -Tail 30
```

### Verify scheduled task exists
```powershell
Get-ScheduledTask -TaskName "NAS Route Switcher"
```

### Check current route
```batch
ping gangal-nas -n 1
```

### View current adapters
```powershell
Get-NetAdapter | Select-Object Name, Status, LinkSpeed
```

### Force route refresh
```
.\update-nas-route.bat
```

## Rollback

To disable auto-routing:

1. Uninstall the scheduled task:
   ```powershell
   .\uninstall-scheduled-task.ps1
   ```

2. Remove hosts file entries (edit as Admin):
   ```
   C:\Windows\System32\drivers\etc\hosts
   ```
   Delete lines containing `gangal-nas`

## License

MIT
