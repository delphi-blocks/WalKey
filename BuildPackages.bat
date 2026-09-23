@echo off
REM ============================================================
REM  Build the WalKey runtime packages
REM
REM  Usage:
REM    BuildPackages.bat                 - Delphi 13 (default)
REM    BuildPackages.bat 22.0^|23.0^|37.0  - pick the Studio version
REM
REM  WalKey.dpk needs nothing but the RTL. WalKeyNeon.dpk additionally
REM  requires the Neon package (Neon.dcp) to be built and installed, and
REM  Neon's source either in Libs\Neon or pointed at by the NEON env var.
REM ============================================================
setlocal

set "STUDIO_VERSION=%1"
if "%STUDIO_VERSION%"=="" set "STUDIO_VERSION=37.0"

set "BDS=C:\Program Files (x86)\Embarcadero\Studio\%STUDIO_VERSION%"
set "BDSINCLUDE=%BDS%\include"
set "BDSCOMMONDIR=C:\Users\Public\Documents\Embarcadero\Studio\%STUDIO_VERSION%"
set "FrameworkDir=C:\Windows\Microsoft.NET\Framework\v4.0.30319"
set "FrameworkVersion=v4.5"
set "FrameworkSDKDir="
set "PATH=%FrameworkDir%;%FrameworkSDKDir%;%BDS%\bin;%BDS%\bin64;%PATH%"
set "LANGDIR=EN"
set "PLATFORM="
set "PlatformSDK="

if not exist "%BDS%\bin\dcc32.exe" (
  echo [ERROR] Delphi %STUDIO_VERSION% not found at "%BDS%"
  exit /b 1
)

if "%NEON%"=="" (
  if exist "%~dp0Libs\Neon\Source" set "NEON=%~dp0Libs\Neon"
)

echo [BUILD] WalKey packages - Delphi %STUDIO_VERSION%
cd /d "%~dp0Packages\11AndLater"
msbuild WalKeyGroup.groupproj /t:Build /p:config=Release /p:platform=Win32 /p:SkipResGeneration=true
if %ERRORLEVEL% NEQ 0 (
  echo.
  echo =================================================
  echo ===    WalKey Packages Failed to Build       ===
  echo =================================================
  exit /b 1
)

echo.
echo [OK] Packages built
exit /b 0
