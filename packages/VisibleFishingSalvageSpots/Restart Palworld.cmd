@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\restart-palworld.ps1"
if errorlevel 1 (
  echo.
  echo Restart failed. Review the error above.
  pause
)
