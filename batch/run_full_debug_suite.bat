@echo off
setlocal EnableExtensions

set "ROOT=%~dp0.."
set "EXE=%ROOT%\GameDev.exe"

if not exist "%EXE%" (
  echo [run_full_debug_suite] ERROR: "%EXE%" not found.
  pause
  exit /b 1
)

call "%~dp0run_closeall.bat"

start "TEST_REALM" /D "%ROOT%" "%EXE%" --mode=realm

REM Small delay so realm is ready
timeout /t 1 >nul

start "TEST_CLIENT_1" /D "%ROOT%" "%EXE%" --mode=client
start "TEST_CLIENT_2" /D "%ROOT%" "%EXE%" --mode=client
start "TEST_CLIENT_3" /D "%ROOT%" "%EXE%" --mode=client