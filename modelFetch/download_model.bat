@echo off
setlocal enabledelayedexpansion

set "hash="
for /f "usebackq delims=" %%a in ("model_version") do set "hash=%%a"
set "model=rnnoise_data-%hash%.tar.gz"

if not exist %model% (
    echo Downloading latest model
    powershell -Command "Invoke-WebRequest -Uri https://media.xiph.org/rnnoise/models/%model% -OutFile '%model%'"
)

where certutil >nul 2>nul
if %errorlevel%==0 (
    echo Validating checksum
    set "checksum=%hash%"
    for /f "delims=" %%b in ('certutil -hashfile %model% SHA256 ^| findstr /i /v "hash"') do set "checksum2=%%b"
    set "checksum2=!checksum2: =!"
    if /i not "!checksum!"=="!checksum2!" (
        echo Aborting due to mismatching checksums. This could be caused by a corrupted download of %model%.
        echo Consider deleting local copy of %model% and running this script again.
        exit /b 1
    ) else (
        echo checksums match
    )
) else (
    echo Could not find certutil; skipping verification. Please verify manually that sha256 hash of %model% matches %hash%.
)

where tar >nul 2>nul
if %errorlevel%==0 (
    tar -xvzf %model%
) else (
    echo Could not find tar; please extract %model% manually.
)
