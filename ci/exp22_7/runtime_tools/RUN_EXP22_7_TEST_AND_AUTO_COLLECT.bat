@echo off
setlocal
cd /d "%~dp0"

if not exist "%~dp0WolfSP.exe" (
  echo ERROR: WolfSP.exe was not found next to this BAT file.
  exit /b 1
)
if not exist "%~dp0EXP22_7_TEST_AND_AUTO_COLLECT.ps1" (
  echo ERROR: EXP22_7_TEST_AND_AUTO_COLLECT.ps1 was not found.
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0EXP22_7_TEST_AND_AUTO_COLLECT.ps1"
set "RC=%ERRORLEVEL%"
exit /b %RC%
