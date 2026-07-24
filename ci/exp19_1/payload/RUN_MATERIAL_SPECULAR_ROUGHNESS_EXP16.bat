@echo off
setlocal
cd /d "%~dp0"
echo MATERIAL-AWARE SPECULAR / ROUGHNESS VISUAL LAB 16
echo Base: Stable Clear v2.2 + Real Mipmaps + Polygon Offset + Dynamic Light Quality + Fog 15.1
echo.
echo Use a scene containing a stone wall, zombie or character, first-person weapon and bright light.
echo Keep the camera fixed. Press F6-F12 and wait about 5 seconds after each key.
echo The collector saves three external PNG frames for every mode.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MATERIAL_SPECULAR_EXP16_RUN_AND_COLLECT.ps1"
if errorlevel 1 (
  echo.
  echo ERROR: Material-Aware Specular Experiment 16 launcher failed.
  pause
  exit /b 1
)
echo.
echo Experiment finished. Check the test_results folder.
pause
endlocal
