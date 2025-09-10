@echo off
setlocal
set SCRIPT_DIR=%~dp0

rem Usage examples:
rem   scripts\fetch_real_data.bat scripts\urls_guitar.txt scripts\urls_noise.txt data\guitar_clean data\interfere

set GUITAR_URLS=%1
set NOISE_URLS=%2
set GUITAR_OUT=%3
set NOISE_OUT=%4

powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%fetch_real_data.ps1" -GuitarUrls "%GUITAR_URLS%" -NoiseUrls "%NOISE_URLS%" -GuitarOut "%GUITAR_OUT%" -NoiseOut "%NOISE_OUT%"

endlocal
