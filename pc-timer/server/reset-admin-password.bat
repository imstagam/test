@echo off
rem Set a new admin password for the management page (asks for administrator rights)
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%ProgramFiles%\PCTimerServer\server.ps1" -Init
pause
