@echo off
setlocal EnableExtensions
title MONTORCO CO2 sensor agent setup

set "BASE=https://eco.curxtor.ru/co2"
set "DIR=%USERPROFILE%\MONTORCO-Agent"
set "PYTHON="
set "LOG=%USERPROFILE%\MONTORCO-Agent\agent.log"

if not exist "%DIR%" mkdir "%DIR%" >nul 2>nul
if not exist "%DIR%" goto :setup_error
cd /d "%DIR%"

where py >nul 2>nul
if not errorlevel 1 (
  py -3 --version >nul 2>nul
  if not errorlevel 1 set "PYTHON=py -3"
)

if not defined PYTHON (
  where python >nul 2>nul
  if not errorlevel 1 (
    python -c "import sys; raise SystemExit(sys.version_info.major != 3)" >nul 2>nul
    if not errorlevel 1 set "PYTHON=python"
  )
)

if not defined PYTHON call :install_python
if not defined PYTHON goto :setup_error

powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest '%BASE%/remote_agent.py' -OutFile '%DIR%\remote_agent.py'" >nul 2>nul
if errorlevel 1 goto :setup_error

if not exist ".venv\Scripts\python.exe" (
  %PYTHON% -m venv .venv >>"%LOG%" 2>&1
  if errorlevel 1 goto :setup_error
)

".venv\Scripts\python.exe" -m pip install --disable-pip-version-check --quiet --upgrade pip hidapi >>"%LOG%" 2>&1
if errorlevel 1 goto :setup_error

set "LOCATION_ARGS="
for /f "tokens=1,2 delims=," %%A in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $g=Invoke-RestMethod 'https://ipapi.co/json/' -TimeoutSec 5; if ($null -ne $g.latitude -and $null -ne $g.longitude) { [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0},{1}', $g.latitude, $g.longitude) } } catch {}"') do set "LOCATION_ARGS=--latitude %%A --longitude %%B"

powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = Start-Process -FilePath '%DIR%\.venv\Scripts\pythonw.exe' -ArgumentList 'remote_agent.py --url %BASE% %LOCATION_ARGS%' -WorkingDirectory '%DIR%' -WindowStyle Hidden -PassThru; Set-Content -Path '%DIR%\agent.pid' -Value $p.Id"
if errorlevel 1 goto :setup_error
exit /b 0

:install_python
where winget >nul 2>nul
if not errorlevel 1 (
  winget install --id Python.Python.3.12 --exact --scope user --silent --accept-package-agreements --accept-source-agreements >>"%LOG%" 2>&1
  if not errorlevel 1 (
    if exist "%LocalAppData%\Programs\Python\Python312\python.exe" set "PYTHON="%LocalAppData%\Programs\Python\Python312\python.exe""
    if not defined PYTHON (
      where py >nul 2>nul
      if not errorlevel 1 set "PYTHON=py -3"
    )
  )
)
if defined PYTHON exit /b 0

set "INSTALLER=%TEMP%\montorco-python-installer.exe"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe' -OutFile '%INSTALLER%'" >>"%LOG%" 2>&1
if errorlevel 1 exit /b 0
"%INSTALLER%" /quiet InstallAllUsers=0 PrependPath=0 Include_test=0 Include_launcher=1 >>"%LOG%" 2>&1
if errorlevel 1 exit /b 0
if exist "%LocalAppData%\Programs\Python\Python312\python.exe" set "PYTHON="%LocalAppData%\Programs\Python\Python312\python.exe""
exit /b 0

:setup_error
echo Agent setup failed. Details: "%LOG%"
timeout /t 8 /nobreak >nul
exit /b 1
