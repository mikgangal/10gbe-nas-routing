# Uninstall Scheduled Task for NAS Route Switcher
# Run as Administrator

$TaskName = "NAS Route Switcher"

# Check admin privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: Run as Administrator" -ForegroundColor Red
    exit 1
}

Write-Host "=== Uninstalling NAS Route Switcher Scheduled Task ===" -ForegroundColor Cyan
Write-Host ""

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Task '$TaskName' removed successfully!" -ForegroundColor Green
} else {
    Write-Host "Task '$TaskName' not found." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Note: The hosts file still contains the NAS entries." -ForegroundColor Gray
Write-Host "Run update-nas-route.ps1 manually if you need to switch routes." -ForegroundColor Gray
Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Cyan
