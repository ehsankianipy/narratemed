@echo off
echo.
echo  NarrateMed Installer
echo  ──────────────────────────────────────
echo  Starting installation...
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0install.ps1"
if %ERRORLEVEL% NEQ 0 (
  echo.
  echo  Something went wrong. See the red text above for details.
)
echo.
pause
