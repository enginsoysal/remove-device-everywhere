# Changelog

All notable changes to Remove Device Everywhere are documented here.

## 1.1.0 - 2026-08-17

### Added

- Source selection for Intune, Windows Autopilot, and Entra ID.
- Safe removal ordering: Intune, then Autopilot, then Entra ID.
- Exact, partial, and linked match labels.
- Input term, last activity, enrollment, ownership, expected action, and result status columns.
- Bulk **Remove Selected** and dry-run CSV export.
- Pending and skipped removal outcomes.
- Tenant-aware audit fields with UTC timestamps and session IDs.
- Retry handling for Graph 429 and transient 5xx responses.
- Test-only `-NoGui` loading mode.
- Rebuilt executable with 1.1.0 version metadata and a published SHA-256 checksum.

### Changed

- Linked cleanup is disabled by default.
- Automatic remove-all operations exclude partial matches.
- Autopilot list and delete requests use Microsoft Graph v1.0.
- Failed and pending bulk results remain visible.
- Temporary PSGallery trust changes are restored after module installation.
- The interface and documentation now explain the possible retire or wipe impact of Intune deletion.

### Fixed

- Bulk audit rows now retain the input term associated with each result.
- Skipped operations are no longer counted or audited as deleted.
- Bulk failures are no longer removed from the result grid.
- The About version and GitHub Help link now follow the current release.

## 1.0.1 - 2026-03-30

- Stabilized PowerShell 5.1 WinForms binding behavior.
- Hardened single and bulk search/removal handlers.
- Added completion confirmations and input reset behavior.

## 1.0.0

- Initial public release.
