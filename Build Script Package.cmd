@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Build Codex Repair Script Package

set "PS_EXE="
where pwsh.exe >nul 2>&1 && set "PS_EXE=pwsh.exe"
if not defined PS_EXE where powershell.exe >nul 2>&1 && set "PS_EXE=powershell.exe"
if not defined PS_EXE (
    echo ERROR: PowerShell 5.1 or newer was not found in PATH.
    pause
    exit /b 2
)

"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build-script-package.ps1" -Force
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" pause
exit /b %RESULT%
