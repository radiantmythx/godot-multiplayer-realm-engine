@echo off
setlocal

REM Launch windows with deterministic titles
start "TEST_REALM" "%~dp0run_realm.bat"
timeout /t 2 >nul
start "TEST_CLIENT_1" "%~dp0run_client.bat"
timeout /t 1 >nul
start "TEST_CLIENT_2" "%~dp0run_client.bat"
timeout /t 1 >nul
start "TEST_CLIENT_3" "%~dp0run_client.bat"

REM Give them a moment to create windows
timeout /t 2 >nul

REM Arrange into 4 quadrants using PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='SilentlyContinue';" ^
  "Add-Type @' " ^
  "using System; using System.Runtime.InteropServices;" ^
  "public class W {" ^
  "  [DllImport(\"user32.dll\")] public static extern bool MoveWindow(IntPtr hWnd,int X,int Y,int nW,int nH,bool bRepaint);" ^
  "  [DllImport(\"user32.dll\")] public static extern bool ShowWindow(IntPtr hWnd,int nCmdShow);" ^
  "}'@;" ^
  "function Get-HwndByTitle([string]$t) {" ^
  "  for($i=0;$i -lt 60;$i++){" ^
  "    $p = Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -eq $t } | Select-Object -First 1;" ^
  "    if($p){ return $p.MainWindowHandle }" ^
  "    Start-Sleep -Milliseconds 200" ^
  "  }" ^
  "  return [IntPtr]::Zero" ^
  "}" ^
  "$sw = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Width;" ^
  "$sh = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height;" ^
  "$sx = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.X;" ^
  "$sy = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Y;" ^
  "$w = [int]($sw/2); $h = [int]($sh/2);" ^
  "Add-Type -AssemblyName System.Windows.Forms;" ^
  "$wins = @(" ^
  "  @{title='TEST_REALM';     x=$sx;      y=$sy      }," ^
  "  @{title='TEST_CLIENT_1'; x=$sx+$w;   y=$sy      }," ^
  "  @{title='TEST_CLIENT_2'; x=$sx;      y=$sy+$h   }," ^
  "  @{title='TEST_CLIENT_3'; x=$sx+$w;   y=$sy+$h   }" ^
  ");" ^
  "foreach($it in $wins){" ^
  "  $hwnd = Get-HwndByTitle $it.title;" ^
  "  if($hwnd -ne [IntPtr]::Zero){" ^
  "    [W]::ShowWindow($hwnd, 9) | Out-Null; # restore" ^
  "    [W]::MoveWindow($hwnd, $it.x, $it.y, $w, $h, $true) | Out-Null;" ^
  "  }" ^
  "}"

endlocal