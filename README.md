# Remove Device Everywhere

One Windows GUI to find and safely remove device records across Microsoft Intune, Microsoft Entra ID, and Windows Autopilot.

## What's new in 1.1

Version 1.1 is the Safe Cleanup release.

- Choose which sources to search: Intune, Autopilot, and Entra ID.
- Process removals in the safer order Intune -> Autopilot -> Entra ID.
- Keep linked cleanup off by default.
- Label exact, linked, and partial matches in the results grid.
- Exclude partial matches from **Remove Exact Found**. Partial matches require explicit row selection.
- Show the input term, last activity, enrollment information, expected action, and per-record status.
- Keep failed and pending bulk records visible for review or retry.
- Export the bulk result set as a dry-run CSV plan.
- Record tenant, Graph account, session ID, UTC time, input term, match type, and outcome in the audit CSV.
- Retry temporary Microsoft Graph failures and throttled requests.
- Use the stable Microsoft Graph v1.0 list and delete endpoints for Windows Autopilot.

See [CHANGELOG.md](CHANGELOG.md) for the complete release history.

## Safety notice

This tool performs destructive administrative actions.

- Deleting an Intune managed-device object is not always a database-only cleanup. Depending on the platform and enrollment type, Intune can initiate a retire or wipe action.
- For Windows Autopilot deregistration, remove the Intune object before the Autopilot registration.
- Microsoft recommends that the related Entra device identity is not manually deleted by default during a normal Autopilot deregistration.
- Entra device deletion is permanent and can affect device-based access, Windows Hello for Business, and stored device details.
- Review **Expected action**, **Match**, tenant ID, and the removal preview before confirming.

Use **Remove Selected** for exceptional or partial matches. Use **Remove Exact Found** only after reviewing all exact and linked results.

## Features

- GUI-first single-device and bulk workflows.
- Search by device name, serial number, managed-device ID, or Azure device ID where supported.
- Selectable Intune, Autopilot, and Entra ID sources.
- Exact-versus-partial match protection.
- Linked-record expansion by serial number or Azure device ID, off by default.
- Ordered removal plans.
- Per-record Deleted, AlreadyAbsent, Pending, Failed, and Skipped outcomes.
- CSV/TXT bulk input and dry-run CSV export.
- Tenant-aware CSV audit logging.
- Microsoft Graph paging and transient-error retry handling.

## Installation

### PowerShell Gallery

```powershell
Install-Script -Name Remove-DeviceEverywhere -Scope CurrentUser
Remove-DeviceEverywhere.ps1
```

### GitHub

```powershell
git clone https://github.com/enginsoysal/remove-device-everywhere.git
cd remove-device-everywhere
Set-ExecutionPolicy -Scope Process Bypass
.\Remove-DeviceEverywhere.ps1
```

The repository also includes `dist/Remove-DeviceEverywhere.exe`. Verify it against `dist/SHA256SUMS.txt` before use. The 1.1 executable carries `1.1.0.0` file and product version metadata.

## Usage

1. Launch the script on Windows.
2. Select the sources to search.
3. Click **Connect Graph** and verify the displayed account and tenant ID.
4. Search by device name, serial number, or supported device ID.
5. Review the match type and expected action for every result.
6. Select records and inspect the removal preview.
7. Confirm the ordered removal plan.
8. Review pending or failed rows and the audit CSV.

Bulk mode accepts one value per line or a CSV column. **Export Dry Run** creates a reviewable plan without sending delete requests.

## Permissions

The interactive Graph connection requests these delegated permissions:

- `DeviceManagementManagedDevices.ReadWrite.All`
- `DeviceManagementServiceConfig.ReadWrite.All`
- `Directory.AccessAsUser.All`

`Directory.AccessAsUser.All` is a highly privileged delegated permission required by Microsoft Graph for delegated Entra device deletion. Use an appropriate administrative account and select only the sources required for the cleanup.

Typical supported roles include:

- Intune Administrator
- Cloud Device Administrator
- Windows 365 Administrator
- A custom role with the required delete permissions

## Audit logging

Every removal attempt is written to a session-specific CSV file in `AuditLogs`.

Audit rows include:

- UTC timestamp and session ID
- Tenant ID and connected Graph account
- Original input term and match type
- Source and device identifiers
- Expected action
- Outcome: Deleted, AlreadyAbsent, Pending, Failed, or Skipped
- Diagnostic message

Audit files can contain device and user information. Store and retain them according to your organization's access and retention policies.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7 on Windows
- Internet access to Microsoft Graph and PowerShell Gallery
- Rights to install `Microsoft.Graph.Authentication` for the current user
- An active Intune license when using the Intune APIs
- An account with the required Graph consent and directory roles

## Development

Run the automated checks with Pester 5:

```powershell
Invoke-Pester -Path .\tests -CI
```

The CI workflow validates both Windows PowerShell 5.1 and PowerShell 7. Core functions can be loaded without opening the GUI:

```powershell
. .\Remove-DeviceEverywhere.ps1 -NoGui
```

## Contributing

Issues and focused pull requests are welcome. Add or update tests whenever behavior changes, especially around matching, ordering, audit outcomes, and Graph error handling.

## License

MIT License. See [LICENSE](LICENSE).
