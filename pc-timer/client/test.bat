@echo off
rem Test run: shows the login screen in a normal window. Browsers are NOT closed and Task Manager is NOT blocked.
rem The management server must be running and ServerUrl in config.json must point to it.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0client.ps1" -Test
