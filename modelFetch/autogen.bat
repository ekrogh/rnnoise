@echo off
REM Run this to set up the build system: configure, makefiles, etc.

cd /d %~dp0
call download_model.bat

echo Updating build configuration files for rnnoise, please wait....

autoreconf -isf
