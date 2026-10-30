@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
title CNC DXF Stage 3 - OptiCut Tests

set "SCRIPT=%~dp0Test-Cnc-OptiCut-Stage3.ps1"
if not exist "%SCRIPT%" (
    echo ERROR: The CNC DXF PowerShell script is missing.
    echo Keep this CMD beside the geometry test .ps1 and main script.
    pause
    exit /b 1
)

rem Preflight: all DXF fixtures must be extracted beside this launcher.
if not exist "%~dp0TestFixtures\Legacy-One-Part.dxf" goto :missing_test_files
if not exist "%~dp0TestFixtures\Layered-Original.dxf" goto :missing_test_files
if not exist "%~dp0Sample_A_Valid\01-R.dxf" goto :missing_test_files
if not exist "%~dp0Sample_A_Valid\10-L-Matrix.dxf" goto :missing_test_files

rem Always use the portable runtime shipped with this project.
set "PWSH=%~dp0PowerShell\7\pwsh.exe"
if not exist "%PWSH%" (
    echo ERROR: Portable PowerShell is missing from PowerShell\7.
    echo Copy the ENTIRE project folder.
    pause
    exit /b 1
)

echo Using PowerShell 7: "%PWSH%"
echo.
echo === Stage 3 OptiCut Integration Tests ===
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-Cnc-OptiCut-Stage3.ps1"
if errorlevel 1 (
    echo ERROR: Stage 3 integration tests FAILED.
    pause
    exit /b 1
)
echo.
echo === Stage 2 Geometry Regression ===
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-Cnc-Geometry-Stage2-v3.1.ps1" -ScriptPath "%~dp0Build-Cnc-Dxf-OptiCut-Dual-Format-v4.ps1"
if errorlevel 1 (
    echo ERROR: Stage 2 geometry regression FAILED.
    pause
    exit /b 1
)
echo.
echo === Stage 1 Parser Regression ===
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-Cnc-Safe-Labels-v2.ps1" -ScriptPath "%~dp0Build-Cnc-Dxf-OptiCut-Dual-Format-v4.ps1"
if errorlevel 1 (
    echo ERROR: Stage 1 label regression FAILED.
    pause
    exit /b 1
)
echo.
echo ALL STAGE 1 / 2 / 3 TESTS PASSED. Desktop A and B were NOT touched.
pause
endlocal
exit /b 0

:missing_test_files
echo.
echo ERROR: Stage 3 DXF test folders are missing.
echo Extract the COMPLETE ZIP using Extract All. Do not copy only the CMD or PS1 files.
echo Required folders beside this CMD: TestFixtures and Sample_A_Valid
echo Expected locations:
echo   "%~dp0TestFixtures\Legacy-One-Part.dxf"
echo   "%~dp0Sample_A_Valid\01-R.dxf"
echo NO CNC TESTS RAN. Nothing was changed in Desktop A or B.
pause
exit /b 1
