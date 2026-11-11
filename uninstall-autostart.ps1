# Удаляет автозапуск (задачу планировщика OmenFanWatch) и снимает режим «максимум» вентиляторов.
# Запускать от имени администратора.
$ErrorActionPreference = 'Stop'
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'omen_fan\.ps1.*watch' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
if (Get-ScheduledTask -TaskName 'OmenFanWatch' -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName 'OmenFanWatch' -Confirm:$false
    Write-Host 'Задача OmenFanWatch удалена.'
} else {
    Write-Host 'Задачи OmenFanWatch нет.'
}
& (Join-Path $PSScriptRoot 'omen_fan.ps1') max off
