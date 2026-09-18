@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Codex Repair

set "PORTABLE_ROOT=%~dp0"
set "CODEX_REPAIR_ROOT=%PORTABLE_ROOT%"
set "DOTNET_ROOT=%PORTABLE_ROOT%runtime"
set "DOTNET_ROOT_X64=%DOTNET_ROOT%"
set "DOTNET_MULTILEVEL_LOOKUP=0"
set "APP_DLL=%PORTABLE_ROOT%app\CodexRepair.dll"

if not exist "%DOTNET_ROOT%\dotnet.exe" (
    echo ERROR: Portable .NET runtime is missing.
    echo Please extract the complete ZIP before running.
    pause
    exit /b 2
)
if not exist "%APP_DLL%" (
    echo ERROR: CodexRepair.dll is missing.
    echo Please extract the complete ZIP before running.
    pause
    exit /b 3
)

start "" /b "%DOTNET_ROOT%\dotnet.exe" "%APP_DLL%"
exit /b 0
