# Устанавливает автозапуск наблюдателя omen_fan.ps1 watch при входе в Windows (задача планировщика OmenFanWatch).
# Запускать от имени администратора. Параметры порога: -On 70 -Off 60.
param([int]$On = 70, [int]$Off = 60)
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Запустите PowerShell от имени администратора.'
}
$script = Join-Path $PSScriptRoot 'omen_fan.ps1'
$arg = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" watch -On {1} -Off {2}' -f $script, $On, $Off
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
Register-ScheduledTask -TaskName 'OmenFanWatch' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force `
    -Description 'HP OMEN: максимум оборотов вентиляторов при высокой температуре (omen_fan.ps1 watch)' | Out-Null
Write-Host "Готово: задача OmenFanWatch создана (порог включения $On °C, выключения $Off °C). Запустится при следующем входе."
Write-Host 'Запустить сейчас: Start-ScheduledTask OmenFanWatch'
