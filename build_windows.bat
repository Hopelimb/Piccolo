@echo off
setlocal

set "PICCOLO_ARCH=%~1"
set "PICCOLO_CONFIG=%~2"

if "%PICCOLO_ARCH%"=="" set "PICCOLO_ARCH=x64"
if "%PICCOLO_CONFIG%"=="" set "PICCOLO_CONFIG=Release"

if /I "%PICCOLO_ARCH%"=="x64" (
    set "CONFIGURE_PRESET=vs2026-x64"
) else if /I "%PICCOLO_ARCH%"=="arm64" (
    set "CONFIGURE_PRESET=vs2026-arm64"
) else (
    echo Unsupported architecture: %PICCOLO_ARCH%
    echo Usage: build_windows.bat [x64^|arm64] [Debug^|Release]
    exit /b 2
)

if /I "%PICCOLO_CONFIG%"=="Debug" (
    set "CONFIG_SUFFIX=debug"
) else if /I "%PICCOLO_CONFIG%"=="Release" (
    set "CONFIG_SUFFIX=release"
) else (
    echo Unsupported configuration: %PICCOLO_CONFIG%
    echo Usage: build_windows.bat [x64^|arm64] [Debug^|Release]
    exit /b 2
)

cmake --preset "%CONFIGURE_PRESET%"
if errorlevel 1 exit /b %errorlevel%

cmake --build --preset "%CONFIGURE_PRESET%-%CONFIG_SUFFIX%" --parallel
exit /b %errorlevel%
