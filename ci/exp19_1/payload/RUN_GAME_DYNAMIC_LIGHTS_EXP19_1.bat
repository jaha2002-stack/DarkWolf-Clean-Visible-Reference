@echo off
setlocal
cd /d "%~dp0"
echo DARKWOLF GAME DYNAMIC LIGHTS EXPERIMENT 19.1
echo.
echo Copy this compact test package over your existing Bloom 18.2 game folder.
echo Stand near a wall with a firearm and keep the camera fixed.
echo Wait 3 seconds, press a mode key F6-F12, then press F5 once.
echo F5 performs the synchronized shot and capture sequence.
echo Use F4 if the weapon keeps firing.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0GAME_DYNAMIC_LIGHTS_EXP19_1_RUN_AND_COLLECT.ps1"
if errorlevel 1 (
  echo.
  echo ERROR: Experiment 19.1 launcher failed.
  pause
  exit /b 1
)
echo.
echo Upload the newest GAME_DYNAMIC_LIGHTS_EXP19_1_*.zip from test_results.
pause
endlocal
