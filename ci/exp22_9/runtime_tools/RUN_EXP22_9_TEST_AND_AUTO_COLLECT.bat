@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"

set "ROOT=%CD%"
set "SCRIPT=%ROOT%\EXP22_9_TEST_AND_AUTO_COLLECT.ps1"
set "RESULTS=%ROOT%\EXP22_9_RESULTS"
set "LASTERROR=%RESULTS%\EXP22_9_COLLECTOR_LAST_ERROR.txt"

if not exist "%RESULTS%" mkdir "%RESULTS%" >nul 2>nul
if exist "%LASTERROR%" del /q "%LASTERROR%" >nul 2>nul

if not exist "%ROOT%\WolfSP.exe" (
  echo.
  echo ERROR: WolfSP.exe was not found next to this BAT file.
  echo Expected: %ROOT%\WolfSP.exe
  goto :failed
)

if not exist "%SCRIPT%" (
  echo.
  echo ERROR: EXP22_9_TEST_AND_AUTO_COLLECT.ps1 was not found.
  echo Expected: %SCRIPT%
  goto :failed
)

set "PSEXE="
for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do if not defined PSEXE set "PSEXE=%%I"
if not defined PSEXE set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%PSEXE%" (
  echo.
  echo ERROR: PowerShell was not found.
  echo Expected: %PSEXE%
  goto :failed
)

echo ==============================================================
echo  DarkWolf EXP22.9 automatic test and result collector
echo ==============================================================
echo Game root : %ROOT%
echo PowerShell: %PSEXE%
echo.
echo The game should start now. Close it normally after the test.
echo A ZIP archive will then be created automatically.
echo.

rem Do not pass GameRoot here. The PowerShell script is stored beside WolfSP.exe
rem and uses its own PSScriptRoot. This avoids Windows quoting problems caused
rem by a quoted path ending in a backslash, for example "D:\DarkWolf\".
"%PSEXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Profile "darkwolf_exp22_9_production.cfg"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
  echo.
  echo ERROR: EXP22.9 collector exited with code %RC%.
  if exist "%LASTERROR%" (
    echo.
    echo ---------------- LAST COLLECTOR ERROR ----------------
    type "%LASTERROR%"
    echo ------------------------------------------------------
  )
  goto :failed
)

echo.
echo EXP22.9 test and collection completed successfully.
exit /b 0

:failed
echo.
echo The window is being kept open so the error can be read.
pause
exit /b 1
