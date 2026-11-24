$ErrorActionPreference = "Stop"

$agentDir = [IO.Path]::GetFullPath((Join-Path $env:ProgramData "MONTORCO-Agent"))
$agentScript = Join-Path $agentDir "remote_agent.py"
$pidFile = Join-Path $agentDir "agent.pid"
$taskName = "MONTORCO CO2 Agent"

Write-Host "Останавливаю процессы агента..."
$processIds = @()
$escapedDir = [regex]::Escape($agentDir)
$processes = Get-CimInstance Win32_Process | Where-Object {
    $_.CommandLine -and
    $_.CommandLine -match '(?i)remote_agent\.py' -and
    $_.CommandLine -match $escapedDir
}
$processIds += $processes.ProcessId

if (Test-Path -LiteralPath $pidFile) {
    $savedPid = Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($savedPid -match '^\d+$' -and $processes.ProcessId -contains [int]$savedPid) {
        $processIds += [int]$savedPid
    }
}
$processIds = @($processIds | Sort-Object -Unique)

foreach ($processId in $processIds) {
    Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
}

Start-Sleep -Milliseconds 500
foreach ($processId in $processIds) {
    if (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
        Write-Warning "Не удалось остановить процесс $processId. Закройте его вручную и повторите удаление."
        exit 1
    }
}

if ($processIds.Count -eq 0) {
    Write-Host "Работающие процессы агента не найдены."
} else {
    Write-Host "Остановлены процессы агента: $($processIds -join ', ')"
}

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Удалена задача автозапуска агента."
}

if (Test-Path -LiteralPath $agentDir) {
    Remove-Item -LiteralPath $agentDir -Recurse -Force -ErrorAction Stop
    Write-Host "Удалена папка агента: $agentDir"
} else {
    Write-Host "Папка агента уже отсутствует."
}

Write-Host "Локальные файлы и автозапуск агента удалены."
