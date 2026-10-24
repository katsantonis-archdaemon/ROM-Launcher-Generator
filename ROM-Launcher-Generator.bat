@echo off
REM ============================================================
REM  Launcher for ROM-Launcher-Generator-GUI.ps1
REM  Double-click THIS file instead of the .ps1 directly.
REM
REM  What this does:
REM   1. Removes the "downloaded from the internet" flag Windows
REM      puts on files from browsers/chat downloads, which is what
REM      triggers the blue "Windows protected your PC" warning.
REM   2. Launches the PowerShell script with the execution policy
REM      bypassed for just this one run (doesn't change any
REM      system-wide settings).
REM ============================================================

set "SCRIPT_DIR=%~dp0"
set "PS1_PATH=%SCRIPT_DIR%ROM-Launcher-Generator-GUI.ps1"

if not exist "%PS1_PATH%" (
    echo [ERROR] Could not find ROM-Launcher-Generator-GUI.ps1
    echo Expected it next to this file at:
    echo   %PS1_PATH%
    echo.
    pause
    exit /b 1
)

REM Remove the internet "Mark of the Web" so Windows stops flagging it as untrusted
powershell -NoProfile -Command "Unblock-File -Path '%PS1_PATH%'" >nul 2>nul

REM Launch the GUI script. This console window stays open and shows debug
REM output while the GUI window runs - close it manually when you're done,
REM or closing the GUI window will also end the script.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1_PATH%"

