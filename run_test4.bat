start "TEST_REALM" "%~dp0run_realm.bat"
timeout /t 2 >nul

start "TEST_CLIENT_1" "%~dp0run_client.bat"
start "TEST_CLIENT_2" "%~dp0run_client.bat"
start "TEST_CLIENT_3" "%~dp0run_client.bat"