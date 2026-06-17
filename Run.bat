@echo off
:: Batch script to run PowerShell SDK installer with Admin privileges and Bypass policy
:: Make sure this .bat file and your .ps1 file are in the same folder.

echo Checking for Administrator privileges...
net session >nul 2>&1
if %errorLevel% == 0 (
    goto :runScript
) else (
    echo Requesting Administrator privileges...
    goto :UACPrompt
)

:UACPrompt
    echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin.vbs"
    echo UAC.ShellExecute "cmd.exe", "/c ""%~s0""", "", "runas", 1 >> "%temp%\getadmin.vbs"
    "%temp%\getadmin.vbs"
    del "%temp%\getadmin.vbs"
    exit /B

:runScript
    cd /d "%~dp0"
    echo -----------------------------------------------------------
    echo Launching Android SDK Installer via PowerShell...
    echo -----------------------------------------------------------
    
    :: Change 'flexible_android_sdk.ps1' to match your exact .ps1 filename if it's different
    powershell -NoProfile -ExecutionPolicy Bypass -File "Android_SDK.ps1"
    
    pause