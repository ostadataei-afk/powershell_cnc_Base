@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
title CNC DXF Generator - Portable PowerShell 7
set "SCRIPT=%~dp0Build-Cnc-Dxf-OptiCut-Dual-Format-v4.ps1"
set "PWSH=%~dp0PowerShell\7\pwsh.exe"
if not exist "%SCRIPT%" (
    echo ERROR: CNC script is missing. Copy the entire project folder.
    pause
    exit /b 1
)
if not exist "%PWSH%" (
    echo ERROR: Portable PowerShell is missing from PowerShell\7.
    echo Copy the ENTIRE project folder including all runtime files.
    pause
    exit /b 1
)
echo Using bundled PowerShell: "%PWSH%"
echo Launching: "%SCRIPT%"
if /i "%~1"=="--validate-only" goto validate
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "RUN_RESULT=%ERRORLEVEL%"
echo.
echo Finished with exit code %RUN_RESULT%.
pause
exit /b %RUN_RESULT%
:validate
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -ValidateOnly
exit /b %ERRORLEVEL%
