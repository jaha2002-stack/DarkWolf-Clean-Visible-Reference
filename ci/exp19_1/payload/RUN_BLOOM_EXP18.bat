@echo off
setlocal
cd /d "%~dp0"
echo BLOOM VISUAL LAB 18
echo Base: Stable Clear v2.2 + approved production fixes + Materials 16 R3 + HDR Tone Mapping 17
echo.
echo Use a scene with a torch or lamp, bright metal, dark surroundings, and preferably an explosion or muzzle flash.
echo Keep the camera fixed. Press F6-F12 and wait about 5 seconds after each key.
echo The collector saves three external PNG frames for every mode.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0BLOOM_EXP18_RUN_AND_COLLECT.ps1"
if errorlevel 1 (
  echo.
  echo ERROR: Bloom Experiment 18 launcher failed.
  pause
  exit /b 1
)
echo.
echo Experiment finished. Check the test_results folder.
pause
endlocal
