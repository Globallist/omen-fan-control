# omen-fan-control

Небольшая утилита на PowerShell для ноутбуков **HP OMEN**: следит за температурой и при достижении порога (по умолчанию 70 °C) включает вентиляторы на максимум, а при остывании (60 °C) возвращает управление BIOS.
Работает без OMEN Gaming Hub и без Microsoft Store.

A small PowerShell utility for **HP OMEN** laptops: it watches temperatures and forces the fans to maximum speed when a threshold (default 70 °C) is reached, then hands control back to the BIOS when the machine cools down (60 °C). No OMEN Gaming Hub or Microsoft Store required.

> ⚠️ Утилита управляет оборудованием через недокументированный интерфейс BIOS HP. Используйте на свой риск. Проверено на HP OMEN 16-c0xxx (BIOS F.27, Ryzen 7 5800H, Radeon RX 6600M, Windows 11). На других моделях команды могут не поддерживаться.
> ⚠️ It talks to an undocumented HP BIOS interface. Use at your own risk. Tested on HP OMEN 16-c0xxx only.

## Что умеет

| Команда | Действие |
|---|---|
| `.\omen_fan.ps1 status` | число вентиляторов, обороты (CPU / GPU), режим «максимум», температуры BIOS, зоны ACPI и GPU |
| `.\omen_fan.ps1 max on` / `max off` | включить / снять максимальные обороты вручную |
| `.\omen_fan.ps1 watch [-On 70 -Off 60 -Interval 3 -Dry]` | наблюдатель с гистерезисом; `-Dry` — только писать решения в журнал |

Порог сравнивается с **наибольшей** из четырёх температур:

1. датчик BIOS HP (команда `0x23`);
2. зона ACPI (`MSAcpi_ThermalZoneTemperature`);
3. температура ядра GPU из драйвера AMD;
4. температура «горячей точки» GPU из драйвера AMD.

Температуры GPU читаются через `atiadlxx.dll` (ADL, тот же источник, что и в AMD Software: Adrenalin Edition); запись метрик Adrenalin включать не нужно. Для видеокарт других производителей эти значения будут равны нулю, остальные датчики продолжат работать.

При остановке наблюдателя (Ctrl+C, завершение сессии) режим «максимум» снимается, вентиляторы возвращаются под управление BIOS. Журнал: `%LOCALAPPDATA%\omen-fan\omen_fan.log` (раз в минуту — состояние всех датчиков и обороты).

## Установка

Требуется Windows 10/11, Windows PowerShell 5.1, права администратора (доступ к `root\wmi`).

```powershell
git clone https://github.com/<ваш-аккаунт>/omen-fan-control.git
cd omen-fan-control
powershell -ExecutionPolicy Bypass -File .\omen_fan.ps1 status          # проверка, только чтение
powershell -ExecutionPolicy Bypass -File .\omen_fan.ps1 max on          # вентиляторы должны раскрутиться
powershell -ExecutionPolicy Bypass -File .\omen_fan.ps1 max off
powershell -ExecutionPolicy Bypass -File .\install-autostart.ps1        # автозапуск при входе (задача OmenFanWatch)
```

Удаление: `.\uninstall-autostart.ps1` (от администратора) — убирает задачу и снимает режим «максимум».

## Как это работает

BIOS HP принимает команды через WMI: класс `hpqBIntM` (экземпляр `ACPI\PNP0C14\0_0`) в пространстве `root\wmi`; входные данные — экземпляр `hpqBDataIn` с подписью `0x53 0x45 0x43 0x55`, командой `0x20008` и номером подкоманды. Используются:

| Подкоманда | Смысл |
|---|---|
| `0x10` | число вентиляторов |
| `0x2D` | текущие обороты (байт × 100 об/мин для каждого вентилятора) |
| `0x23` | температура датчика BIOS |
| `0x26` | чтение режима «максимум» |
| `0x27` | включение / выключение режима «максимум» |

Интерфейс изучен по открытому проекту [OmenMon](https://github.com/OmenMon/OmenMon) (Piotr Szczepański, GPL-3.0) — его код здесь не используется, скрипт написан заново. Если нужен полноценный монитор с оболочкой и кривыми вентиляторов, используйте OmenMon.

Проверка на HP OMEN 16: в простое вентиляторы стоят (0 об/мин, параметр BIOS «Fan Always On» выключен); `max on` → около 4400 / 4500 об/мин; `max off` → возврат под управление BIOS.

## Известные ограничения

- Работает только там, где в BIOS есть интерфейс `hpqBIntM` (проверьте: `Get-CimInstance -Namespace root\wmi -ClassName hpqBIntM`).
- Датчик BIOS и зона ACPI не обязательно показывают самую горячую точку; GPU-температуры доступны только для видеокарт AMD с драйвером, содержащим `atiadlxx.dll`.
- BIOS может сам снимать режим «максимум»; наблюдатель проверяет его на каждом шаге и включает снова.

## Лицензия

MIT, см. [LICENSE](LICENSE).
