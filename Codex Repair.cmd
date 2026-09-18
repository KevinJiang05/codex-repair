@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Codex Repair

set "SCRIPT=%~dp0scripts\repair-gui.ps1"
if not exist "%SCRIPT%" (
    echo ERROR: GUI script was not found:
    echo %SCRIPT%
    echo.
    pause
    exit /b 2
)

where pwsh.exe >nul 2>&1
if errorlevel 1 (
    set "PWSH=%~dp0..\..\envs\tools\PowerShell\7.6.3\pwsh.exe"
) else (
    set "PWSH=pwsh.exe"
)

if not exist "%PWSH%" if /i not "%PWSH%"=="pwsh.exe" (
    echo ERROR: PowerShell 7 could not be found.
    echo Expected: %PWSH%
    echo.
    pause
    exit /b 3
)

"%PWSH%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT%"
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" (
    echo.
    echo GUI exited with code %RESULT%.
    pause
)
exit /b %RESULT%
