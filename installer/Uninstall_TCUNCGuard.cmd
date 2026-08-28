@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall_TCUNCGuard.ps1"
if errorlevel 1 (
  echo.
  echo Uninstallation failed. See the message above.
  pause
  exit /b 1
)
echo.
echo TCUNCGuard uninstallation completed.
pause
