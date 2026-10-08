@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -File "%~dp0Collect-AmdNrDiagnostics.ps1" -Interactive
set "collector_exit=%ERRORLEVEL%"
echo.
echo Kod zakonczenia: %collector_exit%
pause
exit /b %collector_exit%
