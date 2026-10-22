@echo off
cd /d "%~dp0"
echo -----------------------------------------------------------
echo Launching Android SDK and Flutter installer...
echo PowerShell will request Administrator privileges when needed.
echo -----------------------------------------------------------
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Android_SDK.ps1"
set "SCRIPT_EXIT=%ERRORLEVEL%"
for /f "usebackq tokens=1,* delims==" %%A in (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Android_SDK.ps1" -PrintShellEnv 2^>nul`) do (
    set "%%A=%%B"
)
echo.
pause
exit /b %SCRIPT_EXIT%
