@echo off
setlocal EnableExtensions
title MONTORCO CO2 sensor agent setup

set "BASE=https://eco.curxtor.ru/co2"
set "DIR=%ProgramData%\MONTORCO-Agent"
set "LOG=%ProgramData%\MONTORCO-Agent\agent.log"
set "PYTHON="

rem The agent is installed as a SYSTEM task and needs administrator rights.
fltmc >nul 2>nul
if errorlevel 1 (
  echo Requesting administrator rights...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b 0
)

if not exist "%DIR%" mkdir "%DIR%" >nul 2>nul
if not exist "%DIR%" goto :setup_error
copy /y "%~f0" "%DIR%\start_agent.bat" >nul
if errorlevel 1 goto :setup_error
cd /d "%DIR%"
if errorlevel 1 goto :setup_error
echo MONTORCO agent setup >"%LOG%"

echo [1/5] Checking Python 3...
where py >nul 2>nul
if not errorlevel 1 (
  py -3 --version >>"%LOG%" 2>&1
  if not errorlevel 1 set "PYTHON=py -3"
)
if not defined PYTHON (
  where python >nul 2>nul
  if not errorlevel 1 (
    python -c "import sys; raise SystemExit(sys.version_info.major != 3)" >>"%LOG%" 2>&1
    if not errorlevel 1 set "PYTHON=python"
  )
)
if not defined PYTHON call :install_python
if not defined PYTHON goto :setup_error

echo [2/5] Downloading agent...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; Invoke-WebRequest '%BASE%/remote_agent.py' -OutFile '%DIR%\remote_agent.py' -TimeoutSec 30" >>"%LOG%" 2>&1
if errorlevel 1 goto :setup_error

echo [3/5] Preparing Python environment...
if not exist ".venv\Scripts\python.exe" (
  %PYTHON% -m venv .venv >>"%LOG%" 2>&1
  if errorlevel 1 goto :setup_error
)

echo [4/5] Installing USB support (may take a minute)...
".venv\Scripts\python.exe" -m pip install --disable-pip-version-check hidapi >>"%LOG%" 2>&1
if errorlevel 1 goto :setup_error

echo [5/6] Registering agent to start with Windows...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $python=Join-Path '%DIR%' '.venv\Scripts\pythonw.exe'; $agent=Join-Path '%DIR%' 'remote_agent.py'; $action=New-ScheduledTaskAction -Execute $python -Argument ('"' + $agent + '" --url %BASE%'); $trigger=New-ScheduledTaskTrigger -AtStartup; $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest; $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1); Register-ScheduledTask -TaskName 'MONTORCO CO2 Agent' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Runs the MONTORCO CO2 sensor agent for all Windows users.' -Force | Out-Null"
if errorlevel 1 goto :setup_error

echo [6/6] Starting agent in background...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $task=Get-ScheduledTask -TaskName 'MONTORCO CO2 Agent'; if ((Get-ScheduledTaskInfo -TaskName 'MONTORCO CO2 Agent' -ErrorAction SilentlyContinue).State -eq 'Running') { exit 0 }; Start-ScheduledTask -InputObject $task; Start-Sleep -Seconds 2; if ((Get-ScheduledTaskInfo -TaskName 'MONTORCO CO2 Agent').State -ne 'Running') { exit 1 }"
if errorlevel 1 goto :setup_error
echo Agent started hidden. It will start automatically with Windows for all users.
timeout /t 3 /nobreak >nul
exit /b 0

:install_python
echo Python 3 is missing. Installing it automatically...
where winget >nul 2>nul
if not errorlevel 1 (
  echo Trying installation with winget...
  winget install --id Python.Python.3.12 --exact --scope machine --accept-package-agreements --accept-source-agreements >>"%LOG%" 2>&1
  if not errorlevel 1 (
    if exist "%ProgramFiles%\Python312\python.exe" set "PYTHON="%ProgramFiles%\Python312\python.exe""
    if not defined PYTHON (
      where py >nul 2>nul
      if not errorlevel 1 set "PYTHON=py -3"
    )
  )
)
if defined PYTHON exit /b 0

echo Installing Python using the official installer...
set "INSTALLER=%TEMP%\montorco-python-installer.exe"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; Invoke-WebRequest 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe' -OutFile '%INSTALLER%' -TimeoutSec 120" >>"%LOG%" 2>&1
if errorlevel 1 exit /b 0
"%INSTALLER%" /quiet InstallAllUsers=1 PrependPath=1 Include_test=0 Include_launcher=1 >>"%LOG%" 2>&1
if errorlevel 1 exit /b 0
if exist "%ProgramFiles%\Python312\python.exe" set "PYTHON="%ProgramFiles%\Python312\python.exe""
exit /b 0

:setup_error
echo Setup failed. See "%LOG%" for details.
pause
exit /b 1
