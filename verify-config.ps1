# 10GbE NAS Configuration Verification Script
# Run after reboot to verify everything is working

Write-Host "=== 10GbE NAS Configuration Verification ===" -ForegroundColor Cyan
Write-Host ""

# Check 10GbE adapter status
Write-Host "1. 10GbE Adapter Status:" -ForegroundColor Yellow
Get-NetAdapter -Name 'Ethernet 2' | Format-Table Name, Status, LinkSpeed -AutoSize

# Check IP configuration
Write-Host "2. IP Configuration:" -ForegroundColor Yellow
Get-NetIPAddress -InterfaceAlias 'Ethernet 2' -AddressFamily IPv4 | Format-Table IPAddress, PrefixLength -AutoSize

# Check hostname resolution
Write-Host "3. Hostname Resolution:" -ForegroundColor Yellow
$pingResult = Test-Connection -ComputerName gangal-nas -Count 1 -ErrorAction SilentlyContinue
if ($pingResult) {
    Write-Host "   gangal-nas resolves to: $($pingResult.Address)" -ForegroundColor Green
} else {
    Write-Host "   gangal-nas resolution FAILED" -ForegroundColor Red
}
Write-Host ""

# Check routing
Write-Host "4. Route to 10.10.x.x:" -ForegroundColor Yellow
Get-NetRoute -DestinationPrefix "10.10.0.0/16" -ErrorAction SilentlyContinue | Format-Table DestinationPrefix, NextHop, InterfaceAlias -AutoSize

# Test SMB connectivity
Write-Host "5. SMB Connectivity Test:" -ForegroundColor Yellow
$smbTest = Test-NetConnection -ComputerName 10.10.10.100 -Port 445
Write-Host "   Interface: $($smbTest.InterfaceAlias)"
Write-Host "   Source IP: $($smbTest.SourceAddress)"
Write-Host "   SMB Port: $(if($smbTest.TcpTestSucceeded){'OPEN'}else{'CLOSED'})"
Write-Host ""

# Check SMB shares
Write-Host "6. NAS Shares:" -ForegroundColor Yellow
try {
    net view \\gangal-nas 2>&1
} catch {
    Write-Host "   Could not list shares - try: net view \\gangal-nas" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== Verification Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "If all checks passed, remap your drive with:" -ForegroundColor White
Write-Host "  net use Z: \\gangal-nas\ssd-m.2 /persistent:yes" -ForegroundColor Gray
