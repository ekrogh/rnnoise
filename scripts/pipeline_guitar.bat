@echo off
setlocal
set SCRIPT_DIR=%~dp0
set REPO_ROOT=%SCRIPT_DIR%..

rem Optional args (synthetic default):
rem   pipeline_guitar.bat 200 10 64
rem Real data example:
rem   pipeline_guitar.bat 5000 100 64 Real D:\data\guitar D:\data\noise
rem Notes
rem - Requires ffmpeg and CMake in PATH.
rem - Builds tools and examples (rnnoise_demo.exe) in build/Release.
rem - PS script defaults to CPU-only Torch; remove -CPUOnly in this .bat if you have CUDA.
rem - Artifacts:
rem   - features: features.f32
rem   - checkpoints: models/checkpoints
rem   - exported C weights copied to src/rnnoise_data.[ch]
rem   - binaries in build/Release (includes rnnoise_demo.exe)

echo --- Usage / Optional args ---
echo   pipeline_guitar.bat 200 10 64
echo   pipeline_guitar.bat 5000 100 64 Real D:\data\guitar D:\data\noise

echo Notes:
echo   - Requires ffmpeg and CMake in PATH.
echo   - Builds tools and examples ^(rnnoise_demo.exe^) in build\Release.
echo   - PS script defaults to CPU-only Torch; remove -CPUOnly in this .bat if you have CUDA.
echo Artifacts:
echo   - features: features.f32
echo   - checkpoints: models/checkpoints
echo   - exported C weights copied to src/rnnoise_data.[ch]
echo   - binaries in build\Release ^(includes rnnoise_demo.exe^)

:: Allow optional args: featureCount epochs batchSize [DataMode] [GuitarDir] [InterfereDir]
set FEATURE_COUNT=%1
if "%FEATURE_COUNT%"=="" set FEATURE_COUNT=100
set EPOCHS=%2
if "%EPOCHS%"=="" set EPOCHS=5
set BATCH=%3
if "%BATCH%"=="" set BATCH=64
set DATAMODE=%4
if "%DATAMODE%"=="" set DATAMODE=Auto
set GUITAR_DIR=%5
set NOISE_DIR=%6

powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%pipeline_guitar.ps1" -VenvPath "D:\venvs\rnnoise312" -FeatureCount %FEATURE_COUNT% -Epochs %EPOCHS% -BatchSize %BATCH% -BuildType Release -CPUOnly -DataMode %DATAMODE% -GuitarDir "%GUITAR_DIR%" -InterfereDir "%NOISE_DIR%"

endlocal