@echo off
setlocal
cd /d "%~dp0"
echo DARKWOLF GAME DYNAMIC LIGHTS BRIDGE EXPERIMENT 19
echo.
echo Select a firearm and stand close to a wall or object.
echo Press F6-F12 one at a time, then fire repeatedly for 4-6 seconds.
echo The collector automatically captures a rapid screenshot burst and runtime log.
echo Keep the same camera position for all modes.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0GAME_DYNAMIC_LIGHTS_EXP19_RUN_AND_COLLECT.ps1"
if errorlevel 1 (
  echo.
  echo ERROR: Experiment 19 launcher failed.
  pause
  exit /b 1
)
echo.
echo Experiment finished. Upload the newest GAME_DYNAMIC_LIGHTS_EXP19_*.zip from test_results.
pause
endlocal
