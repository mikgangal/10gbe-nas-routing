@echo off
echo Remapping Z: drive to NAS via 10GbE...
echo.

net use Z: /delete /y 2>nul
net use Z: \\gangal-nas\ssd-m.2 /persistent:yes

if %errorlevel%==0 (
    echo.
    echo SUCCESS: Z: drive mapped to \\gangal-nas\ssd-m.2
) else (
    echo.
    echo FAILED: Could not map drive. Try rebooting first.
)

pause
