@echo off
REM ============================================================
REM  Build and run the WalKey DUnitX test suite
REM
REM  Usage:
REM    BuildTests.bat                 - build + run (Delphi 13 default),
REM                                     with the 'Nats' category left out
REM    BuildTests.bat 22.0^|23.0^|37.0  - pick the Studio version
REM    BuildTests.bat 37.0 nats       - compile and run only the 'Nats'
REM                                     category, which needs the
REM                                     nats.delphi checkout and a
REM                                     nats-server with JetStream on
REM                                     localhost:4222
REM
REM  Requirements:
REM    - RAD Studio with Delphi (default: Studio\37.0 = Delphi 13)
REM    - DUnitX (https://github.com/VSoftTechnologies/DUnitX) either on the
REM      IDE library path or pointed at by the DUnitX env var
REM    - Neon (https://github.com/paolo-rossi/delphi-neon): set the NEON env
REM      var, or clone it as Libs\Neon in this repo
REM    - nats.delphi (https://github.com/paolo-rossi/nats.delphi) as
REM      Libs\nats.delphi - only for the 'nats' argument below. Without
REM      that argument the suite is built with no NATS reference at all
REM
REM  Only WalKey.Adapters.Neon needs Neon and only WalKey.Stores.NATS needs
REM  nats.delphi; neither is in WalKey.dpk, so the shipped library is RTL alone.
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

set "NATS_FILTER=--exclude:Nats"
set "NATS_DEFINE="
if /i "%~2"=="nats" (
  if not exist "%~dp0Libs\nats.delphi\Source" (
    echo [ERROR] The NATS tests need the nats.delphi checkout
    echo         - https://github.com/paolo-rossi/nats.delphi - cloned
    echo         into Libs\nats.delphi, then retry.
    exit /b 1
  )
  set "NATS_FILTER=--include:Nats"
  REM MSBuild splits a property value on ';', so it has to arrive escaped
  REM - and a batch file needs %% for the literal % that escape is made of.
  set "NATS_DEFINE=%%3BWALKEY_NATS"
)

echo [BUILD] WalKey tests - Delphi %STUDIO_VERSION%
cd /d "%~dp0Tests"
msbuild WalKey.Tests.Framework.dproj /t:Make /p:config=Release /p:platform=Win32 /p:SkipResGeneration=true /property:DCC_Define=CI%NATS_DEFINE%
if %ERRORLEVEL% NEQ 0 (
  echo.
  echo =================================================
  echo ===    WalKey Tests Failed to Compile         ===
  echo =================================================
  exit /b 1
)

echo.
echo [RUN] WalKey.Tests.Framework.exe
"Bin\WalKey.Tests.Framework.exe" %NATS_FILTER%
exit /b %ERRORLEVEL%
