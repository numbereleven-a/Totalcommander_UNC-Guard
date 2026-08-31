# Changelog

## 0.2 — 2026-08-31

- Fixed Autorun startup registration by creating the required saved plugin
  search in addition to the autoload color rule.
- Added reliable per-account `Wincmd.ini` detection before elevation for
  multi-user installations.
- Added support for redirected profiles and `Wincmd.ini` files on UNC network
  shares by converting PowerShell provider paths to native Windows paths.
- Preferred a portable or shared `Wincmd.ini` beside `TOTALCMD64.EXE` over an
  inactive profile copy.
- Improved Total Commander discovery across registry entries, application
  paths, and `totalcmd` folders on all file-system drives.
- Added exact installation stage, Windows account, detected paths, and native
  Windows error details to failure reports, including errors returned through
  elevation.
- Improved installer and uninstaller handling of malformed registry paths and
  manual paths to either the Total Commander folder or `TOTALCMD64.EXE`.

## 0.1.3 — 2026-08-30

- Completed installer rollback for `autorun.cfg` when a later installation step fails.

## 0.1.2 — 2026-08-30

- Added a two-mode installer for Autorun and TCUNCGuard.
- Added automatic Autorun download with primary, direct-source, and mirror fallbacks.
- Added Autorun registration, autoload color-rule setup, backups, and rollback handling.

## 0.1.1 — 2026-08-28

- Added correction of a Cyrillic `с` typed before a drive-letter colon, such as
  `с:\Windows` or `С:`.
- Updated the path normalizer name and test coverage for local and UNC paths.
- Added a release-ready installer layout and bilingual documentation.

## 0.1.0 — 2026-08-28

- Initial experimental release for Total Commander x64.
- Corrected a Cyrillic `с` in administrative UNC shares before processing Enter.
- Added safe Autorun lifecycle handling and a clean stop command.
