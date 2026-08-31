@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install_TCUNCGuard.ps1"
if errorlevel 1 (
  echo.
  echo Installation failed. The exact stage and reason are shown above.
  pause
  exit /b 1
)
echo.
echo TCUNCGuard installation completed.
pause
