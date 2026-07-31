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
  echo Installation or update failed. Review the error above.
  echo Squirrel logs are normally under:
  echo   %%LOCALAPPDATA%%\SquirrelTemp\SquirrelSetup.log
  echo   %%LOCALAPPDATA%%\attendance_ledger\SquirrelSetup.log
  echo Also check Windows Security protection history.
  pause
  exit /b 1
)
echo.
echo Installation or update completed.
pause
