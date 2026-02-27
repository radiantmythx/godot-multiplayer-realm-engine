@echo off
echo ==============================
echo   Closing all GameDev instances
echo ==============================

taskkill /IM GameDev.exe /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq TEST_*" /F >nul 2>&1

echo Done.
timeout /t 1 >nul