# Remove Device Everywhere

PowerShell GUI for searching and deleting matching device records across:

- Intune managed devices
- Microsoft Entra ID devices
- Windows Autopilot device identities

## What it does

You type an exact device name or serial number into the GUI, click **Search**, review the matching records, then delete the selected rows.

When **Also remove linked records with the same serial or Azure device ID** is enabled, the script expands your selection to the linked records for that same device before deletion.

The GUI also includes:

- A live **Removal Preview** grid that shows exactly which records will be deleted
- A **Remove All Found** button for deleting every result returned by the current search
- Automatic CSV audit logging for each delete attempt

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7 on Windows
- Internet access to Microsoft Graph
- Permission to install the `Microsoft.Graph.Authentication` PowerShell module for the current user
- A signed-in account with Graph delegated permissions and directory roles that allow device deletion

The script bootstraps the NuGet package provider and the Graph authentication module automatically for the current user. It is designed to avoid the interactive package-management prompts that PowerShell normally shows.
If the Graph module files were marked as downloaded from the internet, the script also unblocks the installed module files before import so the module can load cleanly.

## Graph permissions requested

- `DeviceManagementManagedDevices.ReadWrite.All`
- `DeviceManagementServiceConfig.ReadWrite.All`
- `Directory.AccessAsUser.All`

For deleting Entra ID devices, the signed-in user also needs an appropriate Microsoft Entra role such as Cloud Device Administrator, Intune Administrator, or another supported role.

## Run

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Remove-DeviceEverywhere.ps1
```

## Audit log

Each run writes a CSV log to the `AuditLogs` folder next to the script.

Example:

```text
AuditLogs\device-removal-20260327-143501.csv
```

The CSV includes timestamp, operator, search term, source system, device identifiers, outcome, and message.

## Connection behavior

After you click **Connect Graph**, the expected next step is the normal Microsoft sign-in flow. If the sign-in window appears behind other windows, bring it to the front and complete authentication there.

## Notes

- Intune managed device deletion uses the `v1.0` Graph endpoint.
- Entra ID device deletion uses the `v1.0` Graph endpoint.
- Windows Autopilot deletion uses the `beta` Graph endpoint because that record type still requires it.
- For Windows Autopilot records, the script also attempts to remove the deployment profile assignment link before deleting the device identity.
- The script removes the record types you select in the results grid, and can expand that selection to linked records for the same device.
- The removal preview updates when you change the current selection or toggle linked cleanup.
- `Remove All Found` deletes every record currently shown in the search results grid.
- Deletion is permanent. Review the selected rows before you confirm.