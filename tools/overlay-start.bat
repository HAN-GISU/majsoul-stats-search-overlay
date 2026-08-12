@echo off
start "" powershell -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0..\app\majsoul-overlay.ps1"
