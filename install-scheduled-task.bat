@echo off
:: Install NAS Route Switcher scheduled task (runs as Administrator)
powershell -Command "Start-Process powershell -ArgumentList '-ExecutionPolicy Bypass -File \"%~dp0install-scheduled-task.ps1\"' -Verb RunAs"
