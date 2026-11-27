@echo off
rem Check the connection from this PC to the management computer
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-connection.ps1"
pause
