@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Codex Repair
set "CODEX_REPAIR_ROOT=%~dp0"
set "APP_EXE=%~dp0app\CodexRepair.exe"
if not exist "%APP_EXE%" (
    echo ERROR: CodexRepair.exe is missing. Extract the complete ZIP before running.
    pause
    exit /b 2
)
start "" /b "%APP_EXE%"
exit /b 0
