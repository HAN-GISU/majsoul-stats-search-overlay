@echo off
rem Create (or repair) the desktop shortcut that starts the overlay without going through the exe
start "" powershell -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0..\app\majsoul-overlay.ps1" -MakeShortcut
