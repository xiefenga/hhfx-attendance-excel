@echo off
setlocal

set "INSTALL_SCRIPT=%~dp0Install-AttendanceLedger.ps1"
if not exist "%INSTALL_SCRIPT%" (
  set "INSTALL_SCRIPT=%~dp0Attendance Ledger Files\Install-AttendanceLedger.ps1"
)

if not exist "%INSTALL_SCRIPT%" (
  echo Installation failed: Install-AttendanceLedger.ps1 was not found.
  echo Extract the complete ZIP before running this script.
  pause
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_SCRIPT%"
if errorlevel 1 (
  echo.
  echo Installation failed. Review the error above.
  pause
  exit /b 1
)
echo.
echo Installation completed.
pause
