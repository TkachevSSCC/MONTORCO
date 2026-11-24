@echo off
setlocal EnableExtensions
title MONTORCO CO2 Agent Removal

fltmc >nul 2>nul
if errorlevel 1 (
  echo Requesting administrator rights...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b 0
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $dir=[IO.Path]::GetFullPath((Join-Path $env:ProgramData 'MONTORCO-Agent')); Write-Host 'Останавливаю процессы агента...'; $escapedDir=[regex]::Escape($dir); $processes=@(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match '(?i)remote_agent\.py' -and $_.CommandLine -match $escapedDir }); $ids=@($processes | ForEach-Object { [int]$_.ProcessId }); foreach($id in $ids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }; Start-Sleep -Milliseconds 700; if(Get-ScheduledTask -TaskName 'MONTORCO CO2 Agent' -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName 'MONTORCO CO2 Agent' -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName 'MONTORCO CO2 Agent' -Confirm:$false; Write-Host 'Удалена задача автозапуска.' }; if(Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force; Write-Host 'Удалена папка агента.' }; Write-Host 'Удаление завершено.'"
if errorlevel 1 (
  echo Не удалось завершить удаление.
  pause
  exit /b 1
)

echo Удаление агента завершено.
pause
