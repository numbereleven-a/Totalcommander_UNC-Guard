# TCUNCGuard

[English README](README.md)

TCUNCGuard 0.1.1 — экспериментальный модуль Windows x64 для внешнего
WDX-плагина Autorun в Total Commander. Перед обработкой Enter в строке пути он
заменяет кириллическую `с`, если она используется как буква диска или как буква
диска административного UNC-ресурса.

```text
с:\Windows          -> c:\Windows
С:                  -> C:
\\server\с$          -> \\server\c$
\\server\С$\Windows -> \\server\C$\Windows
```

Замена выполняется только в начале локального пути и для точного имени ресурса
из двух символов с завершающим `$`. Остальные компоненты пути не изменяются.
Модуль не выполняет сетевые запросы и не сохраняет введённые пути.

## Требования

- Total Commander x64 для Windows
- Внешний [WDX-плагин Autorun](https://totalcmd.net/plugring/autorun.html)

Autorun необходим, но не входит в этот репозиторий и архивы релизов. Установите
его отдельно до установки TCUNCGuard.

## Сборка

Visual Studio 2022 и CMake:

```powershell
cmake -S . -B build -A x64
cmake --build build --config Release
ctest --test-dir build -C Release --output-on-failure
```

Результат сборки — файл `TCUNCGuard.dll64`.

## Установка

1. Установите Autorun и закройте все процессы Total Commander.
2. Распакуйте архив релиза.
3. Запустите `installer/Install_TCUNCGuard.cmd`.

Установщик копирует модуль в каталог `Plugins` Autorun, сохраняет резервную
копию действующего `autorun.cfg` и добавляет такие команды:

```text
LoadLibrary "%COMMANDER_PATH%\Plugins\wdx\Autorun\Plugins\TCUNCGuard.dll"

Pragma AutorunFinalizeSection
TCUNCGuardStop
```

Команда `TCUNCGuardStop` регистрируется после завершения инициализации Autorun
и используется для корректной остановки рабочего потока при выгрузке.

Для удаления закройте Total Commander и запустите
`installer/Uninstall_TCUNCGuard.cmd`. Деинсталлятор удаляет только команды и
файлы TCUNCGuard; внешний Autorun сохраняется.

## Ограничения

- Поддерживаются Windows x64 и стандартная редактируемая строка пути Total
  Commander.
- Исправление выполняется при нажатии Enter, а не непрерывно во время ввода.
- Нестандартные сборки Total Commander и будущие изменения интерфейса могут
  потребовать обновления совместимости.

## Лицензия

TCUNCGuard распространяется по [лицензии MIT](LICENSE). На отдельно
распространяемый плагин Autorun действуют его собственные условия.
