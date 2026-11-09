@echo off
setlocal
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
set /p SENSOR_PATH=Sensor path (press Enter to use the first detected sensor):

echo.
echo Sending readings to %BASE% . Leave this window open while using the sensor.
if "%SENSOR_PATH%"=="" (
  ".venv\Scripts\python.exe" remote_agent.py --url "%BASE%"
) else (
  ".venv\Scripts\python.exe" remote_agent.py --url "%BASE%" --sensor-path "%SENSOR_PATH%"
)
echo.
echo The agent stopped.
pause
exit /b

:python_error
echo Setup failed. Check that Python 3 and an internet connection are available.
pause
exit /b 1
