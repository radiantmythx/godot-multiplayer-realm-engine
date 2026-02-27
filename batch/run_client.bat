@echo off
setlocal EnableExtensions

set "ROOT=%~dp0.."
set "EXE=%ROOT%\GameDev.exe"

if not exist "%EXE%" (
  echo [run_client] ERROR: "%EXE%" not found.
  pause
  exit /b 1
)

start "TEST_CLIENT" /D "%ROOT%" "%EXE%" --mode=client