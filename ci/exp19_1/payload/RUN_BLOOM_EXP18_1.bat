@echo off
setlocal
cd /d "%~dp0"
echo BLOOM VISUAL LAB 18.1 - FINAL SCENE BLOOM
echo Base: Stable Clear v2.2 + approved fixes + Materials 16 R3 + HDR Tone Mapping 17
echo.
echo This revision captures transparent fire, smoke, muzzle flashes and explosions.
echo F7 is Bright Pass Mask and F8 is Bloom Only. They should look obviously different.
echo Keep the camera fixed. Press F6-F12 and wait about 5 seconds after each key.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0BLOOM_EXP18_1_RUN_AND_COLLECT.ps1"
if errorlevel 1 (
  echo.
  echo ERROR: Bloom Experiment 18.1 launcher failed.
  pause
  exit /b 1
)
echo.
echo Experiment finished. Check the test_results folder.
pause
endlocal
