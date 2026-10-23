@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Codex Repair - Script Edition

set "SCRIPT=%~dp0scripts\repair-gui.ps1"
if not exist "%SCRIPT%" (
    echo ERROR: scripts\repair-gui.ps1 is missing.
    echo Please extract the complete ZIP before running.
    pause
    exit /b 2
)

set "PS_EXE="
where pwsh.exe >nul 2>&1 && set "PS_EXE=pwsh.exe"
if not defined PS_EXE where powershell.exe >nul 2>&1 && set "PS_EXE=powershell.exe"
if /i "%PS_EXE%"=="pwsh.exe" (
    for /f %%V in ('pwsh.exe -NoLogo -NoProfile -Command "$PSVersionTable.PSVersion.Major"') do set "PS_MAJOR=%%V"
)
if "%PS_MAJOR%"=="6" set "PS_EXE=powershell.exe"
if not defined PS_EXE (
    echo ERROR: PowerShell 5.1 or newer was not found in PATH.
    pause
    exit /b 3
)

where py.exe >nul 2>&1
if errorlevel 1 (
    where python.exe >nul 2>&1
    if errorlevel 1 (
        echo ERROR: Python 3 was not found in PATH.
        echo Install Python 3 with the standard sqlite3 module, then reopen this launcher.
        echo https://www.python.org/downloads/windows/
        pause
        exit /b 4
    )
)

"%PS_EXE%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT%"
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" (
    echo.
    echo Codex Repair exited with code %RESULT%.
    pause
)
exit /b %RESULT%
