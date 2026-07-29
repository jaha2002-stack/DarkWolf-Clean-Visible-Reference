@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "ROOT=%~dp0"
set "SCRIPT=%ROOT%EXP22_7_TEST_AND_AUTO_COLLECT.ps1"
set "RESULTS=%ROOT%EXP22_7_RESULTS"
set "LASTERROR=%RESULTS%\EXP22_7_COLLECTOR_LAST_ERROR.txt"

if not exist "%RESULTS%" mkdir "%RESULTS%" >nul 2>nul
if exist "%LASTERROR%" del /q "%LASTERROR%" >nul 2>nul

if not exist "%ROOT%WolfSP.exe" (
  echo.
  echo ERROR: WolfSP.exe was not found next to this BAT file.
  echo Expected: %ROOT%WolfSP.exe
  goto :failed
)

if not exist "%SCRIPT%" (
  echo.
  echo ERROR: EXP22_7_TEST_AND_AUTO_COLLECT.ps1 was not found.
  echo Expected: %SCRIPT%
  goto :failed
)

where pwsh.exe >nul 2>nul
if errorlevel 1 (
  set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
) else (
  set "PSEXE=pwsh.exe"
)

if not exist "%PSEXE%" if /i not "%PSEXE%"=="pwsh.exe" (
  echo.
  echo ERROR: PowerShell was not found.
  goto :failed
)

echo ==============================================================
echo  DarkWolf EXP22.7 automatic test and result collector
echo ==============================================================
echo Game root : %ROOT%
echo PowerShell: %PSEXE%
echo.
echo The game should start now. Close the game normally when the test is done.
echo The collector will then create a ZIP archive automatically.
echo.

"%PSEXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -GameRoot "%ROOT%" -Profile "darkwolf_exp22_7_production.cfg"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
  echo.
  echo ERROR: EXP22.7 collector exited with code %RC%.
  if exist "%LASTERROR%" (
    echo.
    echo ---------------- LAST COLLECTOR ERROR ----------------
    type "%LASTERROR%"
    echo ------------------------------------------------------
  )
  goto :failed
)

echo.
echo EXP22.7 test and collection completed successfully.
exit /b 0

:failed
echo.
echo The window is being kept open so the error can be read.
pause
exit /b 1
