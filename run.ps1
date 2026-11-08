# Сайт-визитка CO2: запуск одной командой
# .\run.ps1            — обычный запуск
# .\run.ps1 -Port 8200 — другой порт

param(
    [int]$Port = 8100
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$venv = Join-Path $root ".venv"
$python = Join-Path $venv "Scripts\python.exe"

if (-not (Test-Path $python)) {
    Write-Host "Создаю виртуальное окружение..." -ForegroundColor Cyan
    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($launcher) {
        & py -3 -m venv $venv
    } else {
        & python -m venv $venv
    }
    & $python -m pip install --quiet --disable-pip-version-check -r (Join-Path $root "requirements.txt")
}

Write-Host "Открываю http://127.0.0.1:$Port" -ForegroundColor Green
& $python -m uvicorn server:app --host 127.0.0.1 --port $Port --app-dir $root
