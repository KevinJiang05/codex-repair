@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Build Codex Repair Portable Package

where pwsh.exe >nul 2>&1
if errorlevel 1 (
    echo ERROR: PowerShell 7 is required only to build the release package.
    echo End users do not need PowerShell.
    pause
    exit /b 2
)

pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build-portable.ps1"
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" pause
exit /b %RESULT%
