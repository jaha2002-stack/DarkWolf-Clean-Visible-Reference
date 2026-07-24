@echo off
setlocal
cd /d "%~dp0"
echo HDR-LIKE LINEAR LIGHTING / TONE MAPPING VISUAL LAB 17
echo Base: Stable Clear v2.2 + approved production fixes + Material-Aware Specular 16 R3
echo.
echo Use a scene with a bright torch or lamp, white highlight, dark corridor and visible stone/metal detail.
echo Keep the camera fixed. Press F6-F12 and wait about 5 seconds after each key.
echo The collector saves three external PNG frames for every mode.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0HDR_TONEMAP_EXP17_RUN_AND_COLLECT.ps1"
if errorlevel 1 (
  echo.
  echo ERROR: HDR Tone Mapping Experiment 17 launcher failed.
  pause
  exit /b 1
)
echo.
echo Experiment finished. Check the test_results folder.
pause
endlocal
