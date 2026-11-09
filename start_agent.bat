@echo off
setlocal EnableExtensions EnableDelayedExpansion
title MONTORCO CO2 sensor agent

set "BASE=https://eco.curxtor.ru/co2"
set "DIR=%USERPROFILE%\MONTORCO-Agent"

where py >nul 2>nul
if errorlevel 1 (
  echo Python 3 was not found. Install Python from https://www.python.org/downloads/windows/
  echo Enable "Add python.exe to PATH" during installation, then run this file again.
  pause
  exit /b 1
)

echo Detecting approximate location from public IP...
set "LAT="
set "LON="
for /f "tokens=1,2 delims=," %%A in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $g=Invoke-RestMethod 'https://ipapi.co/json/' -TimeoutSec 5; if ($null -ne $g.latitude -and $null -ne $g.longitude) { [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0},{1}', $g.latitude, $g.longitude) } } catch {}"') do (
  set "LAT=%%A"
  set "LON=%%B"
)
if not "%LAT%"=="" (
  echo Approximate location: !LAT!, !LON!
) else (
  echo Automatic location lookup failed.
)
set /p "LAT=Latitude (Enter to leave blank): "
set /p "LON=Longitude (Enter to leave blank): "

if not exist "%DIR%" mkdir "%DIR%"
cd /d "%DIR%"

echo Downloading the sensor agent...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest '%BASE%/remote_agent.py' -OutFile 'remote_agent.py'"
if errorlevel 1 (
  echo Could not download remote_agent.py
  pause
  exit /b 1
)

if not exist ".venv\Scripts\python.exe" (
  echo Preparing Python environment...
  py -3 -m venv .venv
  if errorlevel 1 goto :python_error
)

echo Installing HID support...
".venv\Scripts\python.exe" -m pip install --disable-pip-version-check hidapi
if errorlevel 1 goto :python_error

echo.
echo Looking for a supported CO2 sensor...
".venv\Scripts\python.exe" remote_agent.py --list
echo.
set /p SENSOR_PATH=Sensor path (press Enter to use all detected sensors):

echo.
echo Starting the sensor agent in the background...
set "LOCATION_ARGS="
if not "%LAT%"=="" if not "%LON%"=="" set "LOCATION_ARGS=--latitude %LAT% --longitude %LON%"
if "%SENSOR_PATH%"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = Start-Process -FilePath '%CD%\.venv\Scripts\pythonw.exe' -ArgumentList 'remote_agent.py --url %BASE% %LOCATION_ARGS%' -WorkingDirectory '%CD%' -WindowStyle Hidden -PassThru; Write-Host ('Agent started in background (PID ' + $p.Id + ').')"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = Start-Process -FilePath '%CD%\.venv\Scripts\pythonw.exe' -ArgumentList 'remote_agent.py --url %BASE% --sensor-path %SENSOR_PATH% %LOCATION_ARGS%' -WorkingDirectory '%CD%' -WindowStyle Hidden -PassThru; Write-Host ('Agent started in background (PID ' + $p.Id + ').')"
)
echo.
echo The agent is running in the background. This window can be closed.
timeout /t 3 /nobreak >nul
exit /b

:python_error
echo Setup failed. Check that Python 3 and an internet connection are available.
pause
exit /b 1
