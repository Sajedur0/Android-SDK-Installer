@echo off
setlocal
cd /d "%~dp0"
echo -----------------------------------------------------------
echo Launching Android SDK and Flutter installer...
echo PowerShell will request Administrator privileges when needed.
echo -----------------------------------------------------------
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Android_SDK.ps1"
set "SCRIPT_EXIT=%ERRORLEVEL%"
echo.
pause
exit /b %SCRIPT_EXIT%
