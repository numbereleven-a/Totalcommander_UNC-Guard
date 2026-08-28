# TCUNCGuard

[Русская версия](README.ru.md)

TCUNCGuard 0.1.1 is an experimental Windows x64 module for the external
Autorun WDX plugin for Total Commander. Before the path bar processes Enter,
it replaces a Cyrillic `с` when it is used as a drive letter or as the drive
letter of an administrative UNC share.

```text
с:\Windows          -> c:\Windows
С:                  -> C:
\\server\с$          -> \\server\c$
\\server\С$\Windows -> \\server\C$\Windows
```

Only the path prefix and the exact two-character administrative share name are
eligible for replacement. Other path components are left unchanged. The
module does not perform network requests or save entered paths.

## Requirements

- Total Commander x64 on Windows
- The external [Autorun WDX plugin](https://totalcmd.net/plugring/autorun.html)

Autorun is required but is not included in this repository or its release
archives. Install it separately before installing TCUNCGuard.

## Build

Visual Studio 2022 and CMake:

```powershell
cmake -S . -B build -A x64
cmake --build build --config Release
ctest --test-dir build -C Release --output-on-failure
```

The resulting module has the name `TCUNCGuard.dll64`.

## Installation

1. Install Autorun and close all Total Commander processes.
2. Extract the release archive.
3. Run `installer/Install_TCUNCGuard.cmd`.

The installer copies the module to Autorun's `Plugins` directory, backs up the
active `autorun.cfg`, and adds the following commands:

```text
LoadLibrary "%COMMANDER_PATH%\Plugins\wdx\Autorun\Plugins\TCUNCGuard.dll"

Pragma AutorunFinalizeSection
TCUNCGuardStop
```

The `TCUNCGuardStop` command is registered after Autorun finalization and is
used to stop the worker thread cleanly when Autorun unloads.

To uninstall, close Total Commander and run
`installer/Uninstall_TCUNCGuard.cmd`. The uninstaller removes only the
TCUNCGuard commands and module; the external Autorun installation is preserved.

## Limitations

- Windows x64 and the standard editable Total Commander path bar are supported.
- Correction is performed when Enter is pressed; it does not rewrite text
  continuously while it is being typed.
- Custom Total Commander builds or future UI changes may require compatibility
  updates.

## License

TCUNCGuard is distributed under the [MIT License](LICENSE). The separately
distributed Autorun plugin is governed by its own terms.
