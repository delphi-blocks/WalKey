@echo off
REM ============================================================
REM  Build and run the WalKey demo
REM
REM  Usage:
REM    BuildDemo.bat                 - build + run (Delphi 13 default)
REM    BuildDemo.bat 22.0^|23.0^|37.0  - pick the Studio version
REM
REM  Needs Neon (the demo shows typed access): set the NEON env var, or
REM  clone delphi-neon into Libs\Neon.
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
  if exist "%~dp0Libs\Neon\Source" (
    set "NEON=%~dp0Libs\Neon"
  ) else (
    echo [ERROR] Set the NEON env var to the delphi-neon checkout
    echo         or clone it into Libs\Neon, then retry.
    exit /b 1
  )
)

echo [BUILD] WalKey demo - Delphi %STUDIO_VERSION%
cd /d "%~dp0Demos\DemoBasic"
msbuild WalKeyDemo.dproj /t:Make /p:config=Release /p:platform=Win32 /p:SkipResGeneration=true %DEMO_DEFINES%
if %ERRORLEVEL% NEQ 0 (
  echo.
  echo =================================================
  echo ===    WalKey Demo Failed to Compile          ===
  echo =================================================
  exit /b 1
)

echo.
"Bin\WalKeyDemo.exe"
exit /b %ERRORLEVEL%
