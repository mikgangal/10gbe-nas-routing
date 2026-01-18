@echo off
:: Run NAS route switcher as Administrator
powershell -Command "Start-Process powershell -ArgumentList '-ExecutionPolicy Bypass -File \"%~dp0update-nas-route.ps1\"' -Verb RunAs"
