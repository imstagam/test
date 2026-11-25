@echo off
rem Test run: 2-minute limit, only closes the browser at the end (no shutdown).
rem Open a browser after starting this to begin the countdown.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0timer.ps1" -TestMinutes 2
