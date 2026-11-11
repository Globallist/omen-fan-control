# Утилита управления вентиляторами HP OMEN.
# Принцип работы (изучен по открытому проекту OmenMon, код не копировался): BIOS HP принимает команды через WMI,
# класс hpqBIntM в root\wmi. Нужная команда «максимальные обороты» — 0x20008 / 0x27, чтение режима — 0x26,
# число вентиляторов — 0x10, обороты — 0x2D (значение × 100 об/мин), температура — 0x23.
#
# Команды:
#   .\omen_fan.ps1 status             — показать вентиляторы, режим «макс», температуры (только чтение)
#   .\omen_fan.ps1 max on|off         — включить/выключить максимальные обороты вручную
#   .\omen_fan.ps1 watch              — следить за температурой: при >= 70 °C включить максимум, при <= 60 °C вернуть авто
#   .\omen_fan.ps1 watch -On 70 -Off 60 -Interval 3 [-Dry]   (-Dry: только писать решения в журнал, вентиляторы не трогать)
# Температура GPU берётся из драйвера AMD (тот же источник, что в Adrenalin: библиотека atiadlxx.dll, ADL2_OverdriveN_Temperature_Get:
# тип 1 — ядро, тип 2 — горячая точка). Порог в watch сравнивается с максимумом из BIOS, зоны ACPI и GPU.
# Журнал: %LOCALAPPDATA%\omen-fan\omen_fan.log (можно задать -LogPath). При остановке (Ctrl+C, закрытие окна) режим «макс» снимается — вентиляторы
# возвращаются под управление BIOS. Автозапуск не настроен: запускать вручную (от имени администратора, если WMI отказывает).
param(
    [string]$Command = 'status',
    [string]$Arg = '',
    [int]$On = 70,
    [int]$Off = 60,
    [int]$Interval = 3,
    [switch]$Dry,
    [string]$LogPath = ''
)
$ErrorActionPreference = 'Stop'
if (-not $LogPath) { $LogPath = Join-Path $env:LOCALAPPDATA 'omen-fan\omen_fan.log' }
$null = New-Item -ItemType Directory -Force -Path (Split-Path $LogPath)
$Log = $LogPath

function Write-Log($text) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $text
    Add-Content -Path $Log -Value $line -Encoding UTF8
    Write-Host $line
}

# Отправка команды в BIOS; возвращает объект с rwReturnCode и Data
function Send-Bios([uint32]$Cmd, [uint32]$Type, [byte[]]$In, [int]$OutSize) {
    $cls = Get-CimClass -Namespace root\wmi -ClassName hpqBDataIn
    $size = 0
    if ($In) { $size = $In.Length }
    $props = @{ Sign = [byte[]](0x53, 0x45, 0x43, 0x55); Command = $Cmd; CommandType = $Type; Size = [uint32]$size }
    if ($In) { $props['hpqBData'] = $In }
    $inst = New-CimInstance -CimClass $cls -Property $props -ClientOnly
    $m = Get-CimInstance -Namespace root\wmi -ClassName hpqBIntM | Select-Object -First 1
    $r = Invoke-CimMethod -InputObject $m -MethodName ('hpqBIOSInt{0}' -f $OutSize) -Arguments @{ InData = $inst }
    return $r.OutData
}
$Zero = [byte[]](0, 0, 0, 0)

# --- температура GPU через драйвер AMD (ADL) ---
$adlSrc = @'
using System;
using System.Runtime.InteropServices;
public static class AdlTemp {
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate IntPtr Alloc(int size);
  [DllImport("atiadlxx.dll", CallingConvention=CallingConvention.Cdecl)] static extern int ADL2_Main_Control_Create(Alloc cb, int connected, out IntPtr ctx);
  [DllImport("atiadlxx.dll", CallingConvention=CallingConvention.Cdecl)] static extern int ADL2_Adapter_NumberOfAdapters_Get(IntPtr ctx, out int n);
  [DllImport("atiadlxx.dll", CallingConvention=CallingConvention.Cdecl)] static extern int ADL2_OverdriveN_Temperature_Get(IntPtr ctx, int adapter, int type, out int milliC);
  static IntPtr ctx = IntPtr.Zero; static Alloc cb; static int n;
  static IntPtr Mem(int s) { return Marshal.AllocCoTaskMem(s); }
  public static bool Init() {
    if (ctx != IntPtr.Zero) return true;
    cb = new Alloc(Mem);
    if (ADL2_Main_Control_Create(cb, 1, out ctx) != 0) { ctx = IntPtr.Zero; return false; }
    ADL2_Adapter_NumberOfAdapters_Get(ctx, out n);
    return true;
  }
  // Возвращает максимум по адаптерам: [0] — ядро, [1] — горячая точка (0, если не прочитано)
  public static double[] Read() {
    double[] r = new double[2];
    if (!Init()) return r;
    for (int a = 0; a < n && a < 16; a++)
      for (int t = 1; t <= 2; t++) {
        int mc; if (ADL2_OverdriveN_Temperature_Get(ctx, a, t, out mc) == 0 && mc > 0 && mc < 150000) { double v = mc / 1000.0; if (v > r[t - 1]) r[t - 1] = v; }
      }
    return r;
  }
}
'@
$adlOk = $false
try { Add-Type -TypeDefinition $adlSrc; $adlOk = [AdlTemp]::Init() } catch { }
function Get-GpuTemp { if (-not $adlOk) { return @(0, 0) }; try { return [AdlTemp]::Read() } catch { return @(0, 0) } }

function Get-MaxFan { $o = Send-Bios 0x20008 0x26 $Zero 4; if ($o.rwReturnCode -ne 0) { throw "BIOS вернул код $($o.rwReturnCode)" }; return ($o.Data[0] -band 1) -eq 1 }
function Set-MaxFan([bool]$v) {
    $b = 0; if ($v) { $b = 1 }
    $o = Send-Bios 0x20008 0x27 ([byte[]]($b, 0, 0, 0)) 0
    if ($o.rwReturnCode -ne 0) { throw "BIOS вернул код $($o.rwReturnCode) при установке режима" }
}
function Get-FanLevels { $o = Send-Bios 0x20008 0x2D $Zero 128; return @(([int]$o.Data[0] * 100), ([int]$o.Data[1] * 100)) }
function Get-BiosTemp { $o = Send-Bios 0x20008 0x23 ([byte[]](1, 0, 0, 0)) 4; return [int]$o.Data[0] }
function Get-AcpiTemp {
    try {
        $z = Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature
        return [int](($z | ForEach-Object { $_.CurrentTemperature / 10 - 273.15 } | Measure-Object -Maximum).Maximum)
    } catch { return 0 }
}

switch ($Command) {
    'status' {
        $fc = (Send-Bios 0x20008 0x10 $Zero 4).Data[0]
        $lv = Get-FanLevels
        Write-Host ("Вентиляторов: {0}; обороты (CPU / GPU): {1} / {2} об/мин" -f $fc, $lv[0], $lv[1])
        Write-Host ("Режим «максимум»: {0}" -f $(if (Get-MaxFan) { 'ВКЛ' } else { 'выкл (авто)' }))
        Write-Host ("Температура BIOS: {0} °C; зона ACPI: {1} °C" -f (Get-BiosTemp), (Get-AcpiTemp))
        $g = Get-GpuTemp
        if ($adlOk -and $g[0] -gt 0) { Write-Host ("Температура GPU (драйвер AMD): ядро {0:N1} °C, горячая точка {1:N1} °C" -f $g[0], $g[1]) } else { Write-Host 'Температура GPU (драйвер AMD): не прочитана' }
    }
    'max' {
        if ($Arg -notin 'on', 'off') { throw 'Использование: omen_fan.ps1 max on|off' }
        Set-MaxFan ($Arg -eq 'on')
        Write-Log ("ручное управление: максимум = {0}; проверка: {1}" -f $Arg, $(if (Get-MaxFan) { 'ВКЛ' } else { 'выкл' }))
    }
    'watch' {
        $mutex = New-Object System.Threading.Mutex($false, 'Global\omen_fan_watch')
        if (-not $mutex.WaitOne(0)) { throw 'Другой экземпляр watch уже работает' }
        Write-Log ("watch: порог включения {0} °C, выключения {1} °C, шаг {2} с{3}" -f $On, $Off, $Interval, $(if ($Dry) { ' (пробный режим, вентиляторы не трогаю)' } else { '' }))
        $maxOn = $false; $tick = 0; $errors = 0
        try {
            while ($true) {
                try {
                    $tb = Get-BiosTemp; $ta = Get-AcpiTemp; $g = Get-GpuTemp; $tg = [int][math]::Ceiling([math]::Max($g[0], $g[1])); $t = [math]::Max([math]::Max($tb, $ta), $tg)
                    $real = Get-MaxFan
                    if (-not $maxOn -and $t -ge $On) {
                        $maxOn = $true
                        if (-not $Dry) { Set-MaxFan $true }
                        Write-Log ("{0} °C >= {1}: включаю максимум (BIOS {2}, ACPI {3}, GPU ядро {4:N0} / горячая точка {5:N0})" -f $t, $On, $tb, $ta, $g[0], $g[1])
                    } elseif ($maxOn -and $t -le $Off) {
                        $maxOn = $false
                        if (-not $Dry) { Set-MaxFan $false }
                        Write-Log ("{0} °C <= {1}: возвращаю авто (BIOS {2}, ACPI {3}, GPU ядро {4:N0} / горячая точка {5:N0})" -f $t, $Off, $tb, $ta, $g[0], $g[1])
                    } elseif ($maxOn -and -not $real -and -not $Dry) {
                        Set-MaxFan $true   # BIOS мог сам снять режим — подтверждаем
                        Write-Log 'режим «максимум» был снят BIOS, включаю снова'
                    }
                    $errors = 0
                    $tick++
                    if (($tick * $Interval) % 60 -lt $Interval) {
                        $lv = Get-FanLevels
                        Write-Log ("состояние: BIOS {0} °C, ACPI {1} °C, GPU ядро {2:N0} / горячая точка {3:N0} °C, максимум {4}, обороты {5}/{6}" -f $tb, $ta, $g[0], $g[1], $(if ($real) { 'ВКЛ' } else { 'выкл' }), $lv[0], $lv[1])
                    }
                } catch {
                    $errors++
                    Write-Log ("ошибка чтения/записи BIOS: {0}" -f $_.Exception.Message)
                    if ($errors -ge 5) { Write-Log 'пять ошибок подряд — останавливаюсь'; break }
                }
                Start-Sleep -Seconds $Interval
            }
        } finally {
            if (-not $Dry) { try { Set-MaxFan $false; Write-Log 'остановка: режим «максимум» снят, вентиляторы под управлением BIOS' } catch { } }
            $mutex.ReleaseMutex()
        }
    }
    default { throw 'Команды: status | max on|off | watch' }
}
