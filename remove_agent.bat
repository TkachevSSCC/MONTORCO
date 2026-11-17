@echo off
setlocal EnableExtensions
title MONTORCO CO2 Agent Removal

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $dir=[IO.Path]::GetFullPath((Join-Path $env:USERPROFILE 'MONTORCO-Agent')); $pidFile=Join-Path $dir 'agent.pid'; $startup=[Environment]::GetFolderPath('Startup'); $shortcut=Join-Path $startup 'MONTORCO CO2 Agent.lnk'; Write-Host 'Останавливаю процессы агента...'; $escapedDir=[regex]::Escape($dir); $processes=@(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match '(?i)remote_agent\.py' -and $_.CommandLine -match $escapedDir }); $ids=@($processes | ForEach-Object { [int]$_.ProcessId }); if (Test-Path -LiteralPath $pidFile) { $saved=Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1; if ($saved -match '^\d+$' -and $ids -contains [int]$saved) { $ids+= [int]$saved } }; $ids=@($ids | Sort-Object -Unique); foreach($id in $ids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }; Start-Sleep -Milliseconds 700; foreach($id in $ids) { if(Get-Process -Id $id -ErrorAction SilentlyContinue) { throw ('Не удалось остановить процесс '+$id) } }; if($ids.Count) { Write-Host ('Остановлены процессы: '+($ids -join ', ')) } else { Write-Host 'Работающие процессы агента не найдены.' }; if(Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force; Write-Host 'Удалён ярлык автозапуска.' }; if(Get-ScheduledTask -TaskName 'MONTORCO CO2 Agent' -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName 'MONTORCO CO2 Agent' -Confirm:$false; Write-Host 'Удалена задача автозапуска.' }; if(Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force; Write-Host 'Удалена папка агента.' }; Write-Host 'Удаление завершено.'"
if errorlevel 1 (
  echo Не удалось завершить удаление.
  pause
  exit /b 1
)

echo Удаление агента завершено.
pause
