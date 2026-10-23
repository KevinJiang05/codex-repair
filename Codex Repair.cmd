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

set "PS_EXE="
where pwsh.exe >nul 2>&1 && set "PS_EXE=pwsh.exe"
if not defined PS_EXE where powershell.exe >nul 2>&1 && set "PS_EXE=powershell.exe"
if /i "%PS_EXE%"=="pwsh.exe" (
    for /f %%V in ('pwsh.exe -NoLogo -NoProfile -Command "$PSVersionTable.PSVersion.Major"') do set "PS_MAJOR=%%V"
)
if "%PS_MAJOR%"=="6" set "PS_EXE=powershell.exe"
if not defined PS_EXE (
    echo ERROR: PowerShell 5.1 or newer could not be found.
    echo.
    pause
    exit /b 3
)

"%PS_EXE%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT%"
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" (
    echo.
    echo GUI exited with code %RESULT%.
    pause
)
exit /b %RESULT%
