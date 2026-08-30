# Changelog

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
