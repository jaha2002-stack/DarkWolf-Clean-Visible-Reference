@echo off
setlocal
cd /d "%~dp0"
echo BLOOM VISUAL LAB 18.2 - DUAL-SOURCE MULTI-SCALE BLOOM
echo Base: Stable Clear v2.2 + approved fixes + Materials 16 R3 + HDR Tone Mapping 17
echo.
echo F7 = opaque HDR source mask.
echo F8 = final-scene source mask including transparent fire and particles.
echo F9 = combined multi-scale Bloom only.
echo F10-F12 = gameplay profiles from subtle to strong.
echo Keep the camera fixed and wait about 5 seconds after each key.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0BLOOM_EXP18_2_RUN_AND_COLLECT.ps1"
if errorlevel 1 (
  echo.
  echo ERROR: Bloom Experiment 18.2 launcher failed.
  pause
  exit /b 1
)
echo.
echo Experiment finished. Check the test_results folder.
pause
endlocal
