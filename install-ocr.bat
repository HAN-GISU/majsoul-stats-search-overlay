@echo off
rem Install Windows OCR language packs (the PowerShell script self-elevates)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-ocr-langs.ps1"
if errorlevel 1 pause
