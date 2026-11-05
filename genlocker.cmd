@echo off
rem Launcher so genlocker.ps1 runs without changing the machine's execution policy.
rem Usage: genlocker.cmd [-Action Lock^|Watch^|Status^|Unlock] [other options]
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0genlocker.ps1" %*
exit /b %ERRORLEVEL%
