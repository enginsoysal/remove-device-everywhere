<#PSScriptInfo

.VERSION 1.1.0

.GUID 876d6ee4-d403-42db-b4e9-e03a7ef6d488

.AUTHOR Engin Soysal

.COMPANYNAME ProSysTech

.COPYRIGHT (c) ProSysTech. All rights reserved.

.TAGS intune entra autopilot graph winforms device cleanup

.LICENSEURI https://github.com/enginsoysal/remove-device-everywhere/blob/main/LICENSE

.PROJECTURI https://github.com/enginsoysal/remove-device-everywhere

.ICONURI https://raw.githubusercontent.com/enginsoysal/remove-device-everywhere/main/screenshots/tab-single-device.png

.RELEASENOTES Safe Cleanup release: adds ordered removal plans, exact-versus-partial match protection, source selection, per-record outcomes, Graph retry handling, stable Autopilot v1.0 endpoints, tenant-aware audit logging, and safer bulk operations.

#>

<#
.SYNOPSIS
PowerShell GUI for searching and removing device records across Intune, Entra ID, and Autopilot.

.DESCRIPTION
Interactive Windows Forms script for operational device cleanup with audit logging.

.PARAMETER NoGui
Loads the core functions without opening the Windows Forms interface. Intended for automated tests.

.PARAMETER SmokeTest
Builds and opens the Windows Forms interface, then closes it immediately. Intended for automated UI startup checks.
#>

param(
    [switch]$NoGui,
    [switch]$SmokeTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Invoke-ExternalPowerShellRelaunchIfNeeded {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if (-not $PSCommandPath) {
        return
    }

    if ($env:REMOVE_DEVICE_EVERYWHERE_EXTERNAL_HOST -eq '1') {
        return
    }

    $isVsCodeHost = ($env:TERM_PROGRAM -eq 'vscode') -or (Get-Module -Name PowerShellEditorServices* -ListAvailable -ErrorAction SilentlyContinue)
    if (-not $isVsCodeHost) {
        return
    }

    [System.Windows.Forms.MessageBox]::Show(
        'This script will reopen in a fresh Windows PowerShell window to avoid Microsoft Graph assembly conflicts inside the VS Code PowerShell host.',
        'Restarting In External PowerShell',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null

    $launchScript = @"
`$env:REMOVE_DEVICE_EVERYWHERE_EXTERNAL_HOST = '1'
& '$PSCommandPath'
"@

    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launchScript))

    try {
        if (-not $PSCmdlet.ShouldProcess($PSCommandPath, 'Relaunch script in external Windows PowerShell')) {
            return
        }

        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile'
            '-ExecutionPolicy'
            'Bypass'
            '-EncodedCommand'
            $encodedCommand
        ) -WindowStyle Normal | Out-Null
        exit
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Automatic relaunch failed: $($_.Exception.Message)`r`n`r`nRun this manually in a normal Windows PowerShell window:`r`n`r`npowershell.exe -ExecutionPolicy Bypass -File `"$PSCommandPath`"",
            'External PowerShell Launch Failed',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        throw
    }
}

if (-not $NoGui) {
    Invoke-ExternalPowerShellRelaunchIfNeeded
}

function Get-AppBasePath {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        return $PSScriptRoot
    }

    if ($MyInvocation -and $MyInvocation.MyCommand) {
        $pathProperty = $MyInvocation.MyCommand.PSObject.Properties['Path']
        if ($pathProperty -and -not [string]::IsNullOrWhiteSpace([string]$pathProperty.Value)) {
            return (Split-Path -Path ([string]$pathProperty.Value) -Parent)
        }
    }

    if ([AppDomain]::CurrentDomain.BaseDirectory) {
        return [AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\\')
    }

    return (Get-Location).Path
}

$script:GraphScopes = @(
    'DeviceManagementManagedDevices.ReadWrite.All'
    'DeviceManagementServiceConfig.ReadWrite.All'
    'Directory.AccessAsUser.All'
)

$script:AppVersion = '1.1.0'
$script:PreferredGraphAuthVersion = if ($PSVersionTable.PSEdition -eq 'Desktop') { '2.33.0' } else { $null }

$script:SearchResults = New-Object System.Collections.Generic.List[object]
$script:PreviewResults = New-Object System.Collections.Generic.List[object]
$script:CurrentSearchTerm = ''
$script:BulkInputTerms = New-Object System.Collections.Generic.List[string]
$script:BulkAllResults = New-Object System.Collections.Generic.List[object]
$script:BulkSearchRunning = $false
$script:BulkRemoveSelectedRequested = $false
$script:PrimaryLogTextBox = $null
$script:SecondaryLogTextBox = $null
$script:GraphContext = $null
$script:SessionId = [guid]::NewGuid().ToString()
$script:AppBasePath = Get-AppBasePath
$script:AuditDirectory = Join-Path -Path $script:AppBasePath -ChildPath 'AuditLogs'
$script:AuditLogPath = Join-Path -Path $script:AuditDirectory -ChildPath ("device-removal-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-UiLog {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TextBox]$TextBox,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] $Message`r`n"

    $targets = New-Object System.Collections.Generic.List[System.Windows.Forms.TextBox]
    [void]$targets.Add($TextBox)

    foreach ($candidate in $script:PrimaryLogTextBox, $script:SecondaryLogTextBox) {
        if ($candidate -and ($targets -notcontains $candidate)) {
            [void]$targets.Add($candidate)
        }
    }

    foreach ($target in $targets) {
        $target.AppendText($line)
        $target.SelectionStart = $target.TextLength
        $target.ScrollToCaret()
    }
}

function Clear-UiLog {
    foreach ($textBox in $script:PrimaryLogTextBox, $script:SecondaryLogTextBox) {
        if ($textBox) {
            $textBox.Clear()
        }
    }
}

function Get-ExceptionSummary {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("Message: $($ErrorRecord.Exception.Message)")
    [void]$lines.Add("Type: $($ErrorRecord.Exception.GetType().FullName)")

    if ($ErrorRecord.FullyQualifiedErrorId) {
        [void]$lines.Add("ErrorId: $($ErrorRecord.FullyQualifiedErrorId)")
    }

    if ($ErrorRecord.CategoryInfo) {
        [void]$lines.Add("Category: $($ErrorRecord.CategoryInfo.Category)")
        if ($ErrorRecord.CategoryInfo.TargetName) {
            $targetName = [string]$ErrorRecord.CategoryInfo.TargetName
            $targetName = [regex]::Replace($targetName, 'Authorization:\s*Bearer\s+[^\r\n]+', 'Authorization: Bearer [REDACTED]')
            [void]$lines.Add("Target: $targetName")
        }
    }

    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.MyCommand) {
        [void]$lines.Add("Command: $($ErrorRecord.InvocationInfo.MyCommand.Name)")
    }

    $inner = $ErrorRecord.Exception.InnerException
    $depth = 0
    while ($inner -and $depth -lt 3) {
        [void]$lines.Add("Inner[$depth]: $($inner.GetType().FullName): $($inner.Message)")
        $inner = $inner.InnerException
        $depth++
    }

    if ($ErrorRecord.ScriptStackTrace) {
        [void]$lines.Add('ScriptStackTrace:')
        foreach ($line in ($ErrorRecord.ScriptStackTrace -split "`r?`n")) {
            if ($line.Trim()) {
                [void]$lines.Add("  $line")
            }
        }
    }

    return ($lines -join [Environment]::NewLine)
}

function Write-UiErrorDetail {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TextBox]$TextBox,

        [Parameter(Mandatory)]
        [string]$Prefix,

        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    Write-UiLog -TextBox $TextBox -Message "$Prefix $($ErrorRecord.Exception.Message)"
    foreach ($line in ((Get-ExceptionSummary -ErrorRecord $ErrorRecord) -split "`r?`n")) {
        Write-UiLog -TextBox $TextBox -Message "  $line"
    }
}

function Initialize-AuditLog {
    if (-not (Test-Path -Path $script:AuditDirectory)) {
        New-Item -Path $script:AuditDirectory -ItemType Directory -Force | Out-Null
    }
}

function Write-AuditEntry {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Record,

        [Parameter(Mandatory)]
        [string]$Outcome,

        [Parameter(Mandatory)]
        [string]$Message
    )

    Initialize-AuditLog

    $recordInputTerm = if ($Record.PSObject.Properties['InputTerm']) { [string]$Record.InputTerm } else { $script:CurrentSearchTerm }
    $recordMatchType = if ($Record.PSObject.Properties['MatchType']) { [string]$Record.MatchType } else { 'Unknown' }
    $tenantId = if ($script:GraphContext -and $script:GraphContext.TenantId) { [string]$script:GraphContext.TenantId } else { '' }
    $graphAccount = if ($script:GraphContext -and $script:GraphContext.Account) { [string]$script:GraphContext.Account } else { $env:USERNAME }

    $auditRecord = [PSCustomObject]@{
        TimestampUtc    = [DateTime]::UtcNow.ToString('o')
        SessionId       = $script:SessionId
        TenantId        = $tenantId
        Operator        = $graphAccount
        SearchTerm      = $recordInputTerm
        MatchType       = $recordMatchType
        Source          = $Record.Source
        DisplayName     = $Record.DisplayName
        SerialNumber    = $Record.SerialNumber
        PrimaryUser     = $Record.PrimaryUser
        OperatingSystem = $Record.OperatingSystem
        RecordId        = $Record.RecordId
        AzureDeviceId   = $Record.AzureDeviceId
        ExpectedAction  = if ($Record.PSObject.Properties['ExpectedAction']) { $Record.ExpectedAction } else { '' }
        Outcome         = $Outcome
        Message         = $Message
    }

    if (Test-Path -Path $script:AuditLogPath) {
        $auditRecord | Export-Csv -Path $script:AuditLogPath -NoTypeInformation -Append
        return
    }

    $auditRecord | Export-Csv -Path $script:AuditLogPath -NoTypeInformation
}

function Initialize-PackageManagementPrerequisite {
    $nugetProvider = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue
    if (-not $nugetProvider -or [version]$nugetProvider.Version -lt [version]'2.8.5.201') {
        Install-PackageProvider -Name NuGet -MinimumVersion '2.8.5.201' -Force -Scope CurrentUser -Confirm:$false | Out-Null
    }

    $psGallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if (-not $psGallery) {
        Register-PSRepository -Default -ErrorAction Stop
        $psGallery = Get-PSRepository -Name PSGallery -ErrorAction Stop
    }

    $originalInstallationPolicy = [string]$psGallery.InstallationPolicy
    if ($originalInstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }

    return $originalInstallationPolicy
}

function Initialize-MicrosoftGraphModule {
    $moduleName = 'Microsoft.Graph.Authentication'
    $requiredVersion = $script:PreferredGraphAuthVersion
    $installedModules = Get-Module -ListAvailable -Name $moduleName

    if ($requiredVersion) {
        $module = $installedModules | Where-Object { $_.Version -eq [version]$requiredVersion } | Select-Object -First 1
    }
    else {
        $module = $installedModules | Sort-Object Version -Descending | Select-Object -First 1
    }

    if (-not $module) {
        $originalInstallationPolicy = Initialize-PackageManagementPrerequisite
        $installParams = @{
            Name              = $moduleName
            Repository        = 'PSGallery'
            Scope             = 'CurrentUser'
            Force             = $true
            AllowClobber      = $true
            Confirm           = $false
        }

        if ($requiredVersion) {
            $installParams.RequiredVersion = $requiredVersion
        }

        try {
            Install-Module @installParams
        }
        finally {
            if ($originalInstallationPolicy -and $originalInstallationPolicy -ne 'Trusted') {
                Set-PSRepository -Name PSGallery -InstallationPolicy $originalInstallationPolicy -ErrorAction SilentlyContinue
            }
        }

        $installedModules = Get-Module -ListAvailable -Name $moduleName
        if ($requiredVersion) {
            $module = $installedModules | Where-Object { $_.Version -eq [version]$requiredVersion } | Select-Object -First 1
        }
        else {
            $module = $installedModules | Sort-Object Version -Descending | Select-Object -First 1
        }
    }

    if (-not $module) {
        if ($requiredVersion) {
            throw "Microsoft.Graph.Authentication $requiredVersion could not be installed."
        }

        throw 'Microsoft.Graph.Authentication could not be installed.'
    }

    Get-ChildItem -Path $module.ModuleBase -Recurse -File | ForEach-Object {
        Unblock-File -Path $_.FullName -ErrorAction SilentlyContinue
    }

    return $module
}

function Connect-DeviceCleanupGraph {
    param(
        [Parameter()]
        [bool]$UseDeviceCode = $false,

        [Parameter()]
        [System.Windows.Forms.TextBox]$LogTextBox
    )

    $module = Initialize-MicrosoftGraphModule
    $modulePathProperty = if ($module) { $module.PSObject.Properties['Path'] } else { $null }
    $moduleImportTarget = if ($modulePathProperty -and -not [string]::IsNullOrWhiteSpace([string]$modulePathProperty.Value)) {
        [string]$modulePathProperty.Value
    }
    elseif ($module -and -not [string]::IsNullOrWhiteSpace([string]$module.ModuleBase)) {
        [string]$module.ModuleBase
    }
    else {
        [string]$module.Name
    }

    Import-Module -Name $moduleImportTarget -Force -ErrorAction Stop
    if ($LogTextBox) {
        Write-UiLog -TextBox $LogTextBox -Message "Loaded $($module.Name) version $($module.Version) from $($module.ModuleBase)"
        Write-UiLog -TextBox $LogTextBox -Message "PowerShell host: $($Host.Name) $($PSVersionTable.PSVersion) [$($PSVersionTable.PSEdition)]"
    }

    $context = Get-MgContext -ErrorAction SilentlyContinue
    $requiredScopes = $script:GraphScopes
    $needsConnect = $true

    if ($context -and $context.Scopes) {
        $missingScope = $requiredScopes | Where-Object { $_ -notin $context.Scopes } | Select-Object -First 1
        if (-not $missingScope) {
            $needsConnect = $false
        }
    }

    if ($needsConnect) {
        if ($UseDeviceCode) {
            if ($LogTextBox) {
                Write-UiLog -TextBox $LogTextBox -Message 'Using device code sign-in. Follow the code prompt shown in the terminal window.'
            }

            Connect-MgGraph -Scopes $requiredScopes -NoWelcome -ContextScope Process -UseDeviceCode | Out-Null
        }
        else {
            if ($LogTextBox) {
                Write-UiLog -TextBox $LogTextBox -Message 'Starting interactive Microsoft sign-in. If no window appears, check behind other windows.'
            }

            Connect-MgGraph -Scopes $requiredScopes -NoWelcome -ContextScope Process | Out-Null
        }
    }

    $script:GraphContext = Get-MgContext
    return $script:GraphContext
}

function ConvertTo-ODataString {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    return $Value.Replace("'", "''")
}

function Test-GuidString {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $guid = [guid]::Empty
    return [guid]::TryParse($Value, [ref]$guid)
}

function Get-EmbeddedGuidValue {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $match = [regex]::Match($Value, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b')
    if ($match.Success) {
        return $match.Value
    }

    return $null
}

function Get-GraphErrorStatusCode {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $responseProperty = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($responseProperty -and $responseProperty.Value) {
        $statusProperty = $responseProperty.Value.PSObject.Properties['StatusCode']
        if ($statusProperty -and $null -ne $statusProperty.Value) {
            try {
                return [int]$statusProperty.Value
            }
            catch {
                Write-Verbose 'Graph status code could not be converted to an integer; parsing the error text instead.'
            }
        }
    }

    $errorDetailsText = ''
    $errorDetailsProperty = $ErrorRecord.PSObject.Properties['ErrorDetails']
    if ($errorDetailsProperty -and $errorDetailsProperty.Value) {
        $messageProperty = $errorDetailsProperty.Value.PSObject.Properties['Message']
        if ($messageProperty) {
            $errorDetailsText = [string]$messageProperty.Value
        }
    }
    $errorText = "$($ErrorRecord.Exception.Message) $errorDetailsText"
    $statusMatch = [regex]::Match($errorText, '(?<!\d)(429|500|502|503|504)(?!\d)')
    if ($statusMatch.Success) {
        return [int]$statusMatch.Groups[1].Value
    }

    return 0
}

function Get-GraphRetryDelaySeconds {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory)]
        [int]$Attempt
    )

    $responseProperty = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($responseProperty -and $responseProperty.Value) {
        $headersProperty = $responseProperty.Value.PSObject.Properties['Headers']
        if ($headersProperty -and $headersProperty.Value) {
            try {
                $retryAfter = $headersProperty.Value['Retry-After']
                if ($retryAfter) {
                    $parsedDelay = 0
                    if ([int]::TryParse([string]$retryAfter, [ref]$parsedDelay) -and $parsedDelay -gt 0) {
                        return [Math]::Min($parsedDelay, 60)
                    }
                }
            }
            catch {
                Write-Verbose 'Graph response headers do not expose Retry-After through an indexer.'
            }
        }
    }

    $errorDetailsText = ''
    $errorDetailsProperty = $ErrorRecord.PSObject.Properties['ErrorDetails']
    if ($errorDetailsProperty -and $errorDetailsProperty.Value) {
        $messageProperty = $errorDetailsProperty.Value.PSObject.Properties['Message']
        if ($messageProperty) {
            $errorDetailsText = [string]$messageProperty.Value
        }
    }
    $errorText = "$($ErrorRecord.Exception.Message) $errorDetailsText"
    $retryMatch = [regex]::Match($errorText, '(?i)retry[- ]after\D{0,8}(\d+)')
    if ($retryMatch.Success) {
        return [Math]::Min([int]$retryMatch.Groups[1].Value, 60)
    }

    return [Math]::Min([Math]::Pow(2, ($Attempt - 1)), 30)
}

function Invoke-DeviceCleanupGraphRequest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri,

        [string]$OutputType,

        [AllowNull()]
        [object]$Body,

        [ValidateRange(1, 10)]
        [int]$MaxAttempts = 4
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $requestParameters = @{
                Method = $Method
                Uri    = $Uri
            }

            if ($OutputType) {
                $requestParameters.OutputType = $OutputType
            }

            if ($null -ne $Body) {
                $requestParameters.Body = $Body
                $requestParameters.ContentType = 'application/json'
            }

            return Invoke-MgGraphRequest @requestParameters
        }
        catch {
            $statusCode = Get-GraphErrorStatusCode -ErrorRecord $_
            $isTransient = $statusCode -in @(429, 500, 502, 503, 504)
            if (-not $isTransient -or $attempt -ge $MaxAttempts) {
                throw
            }

            $delaySeconds = Get-GraphRetryDelaySeconds -ErrorRecord $_ -Attempt $attempt
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Invoke-GraphGetPaged {
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $items = New-Object System.Collections.Generic.List[object]
    $nextLink = $Uri

    while ($nextLink) {
        $response = Invoke-DeviceCleanupGraphRequest -Method GET -Uri $nextLink -OutputType PSObject
        if ($response.value) {
            foreach ($entry in $response.value) {
                [void]$items.Add($entry)
            }
        }

        $nextLinkProperty = $response.PSObject.Properties['@odata.nextLink']
        if ($nextLinkProperty) {
            $nextLink = [string]$nextLinkProperty.Value
        }
        else {
            $nextLink = $null
        }
    }

    Write-Output -NoEnumerate $items
}

function ConvertTo-ObjectArray {
    param(
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        Write-Output -NoEnumerate -InputObject ([object[]]@())
        return
    }

    if ($InputObject -is [string] -or $InputObject -isnot [System.Collections.IEnumerable]) {
        Write-Output -NoEnumerate -InputObject ([object[]]@($InputObject))
        return
    }

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($item in $InputObject) {
        [void]$items.Add($item)
    }

    Write-Output -NoEnumerate -InputObject $items.ToArray()
}

function Test-IsGraphInternalServerError {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    return $ErrorRecord.Exception.Message -match 'InternalServerError'
}

function Get-UniqueResultsByRecordId {
    param(
        [AllowNull()]
        [object]$Items
    )

    $unique = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($item in (ConvertTo-ObjectArray -InputObject $Items)) {
        if (-not $item) {
            continue
        }

        $key = "$($item.Source)|$($item.RecordId)"
        if ($seen.Add($key)) {
            [void]$unique.Add($item)
        }
    }

    return $unique
}

function Invoke-SearchBlock {
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [Parameter(Mandatory)]
        [System.Windows.Forms.TextBox]$LogTextBox
    )

    try {
        $result = & $Action
        return ConvertTo-ObjectArray -InputObject $result
    }
    catch {
        Write-UiErrorDetail -TextBox $LogTextBox -Prefix "$Label failed:" -ErrorRecord $_
        return @()
    }
}

function Get-GraphObject {
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    try {
        return Invoke-DeviceCleanupGraphRequest -Method GET -Uri $Uri -OutputType PSObject
    }
    catch {
        if ($_.Exception.Message -match '404|NotFound') {
            return $null
        }

        throw
    }
}

function Confirm-GraphDeletion {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [int]$MaxAttempts = 5,

        [int]$DelayMilliseconds = 1500
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if (-not (Get-GraphObject -Uri $Uri)) {
            return $true
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }

    return $false
}

function ConvertTo-ResultObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$DisplayName,

        [string]$SerialNumber,
        [string]$PrimaryUser,
        [string]$OperatingSystem,
        [string]$RecordId,
        [string]$AzureDeviceId,
        [string]$DeleteUri,
        [string]$Details,
        [string]$InputTerm = $script:CurrentSearchTerm,
        [ValidateSet('Exact', 'Partial', 'Linked')]
        [string]$MatchType = 'Exact',
        [string]$LastActivity,
        [string]$EnrollmentType,
        [string]$Ownership,
        [string]$ExpectedAction,
        [string]$ResultStatus = 'Found'
    )

    if (-not $ExpectedAction) {
        $ExpectedAction = switch ($Source) {
            'Intune Managed Device' { 'Delete from Intune (may retire or wipe)' }
            'Windows Autopilot' { 'Deregister from Windows Autopilot' }
            'Entra ID Device' { 'Delete Entra device identity' }
            default { 'Delete record' }
        }
    }

    [PSCustomObject]@{
        InputTerm      = $InputTerm
        MatchType      = $MatchType
        Source          = $Source
        DisplayName     = $DisplayName
        SerialNumber    = $SerialNumber
        PrimaryUser     = $PrimaryUser
        OperatingSystem = $OperatingSystem
        RecordId        = $RecordId
        AzureDeviceId   = $AzureDeviceId
        LastActivity    = $LastActivity
        EnrollmentType  = $EnrollmentType
        Ownership       = $Ownership
        ExpectedAction  = $ExpectedAction
        ResultStatus    = $ResultStatus
        DeleteUri       = $DeleteUri
        Details         = $Details
    }
}

function Find-ManagedDeviceMatchByRecordId {
    param(
        [Parameter(Mandatory)]
        [string]$SearchTerm
    )

    $recordId = Get-EmbeddedGuidValue -Value $SearchTerm
    if (-not $recordId) {
        return @()
    }

    $device = Get-GraphObject -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$recordId"
    if (-not $device) {
        return @()
    }

    return @(
        ConvertTo-ResultObject -Source 'Intune Managed Device' `
            -DisplayName $device.deviceName `
            -SerialNumber $device.serialNumber `
            -PrimaryUser $device.userPrincipalName `
            -OperatingSystem $device.operatingSystem `
            -RecordId $device.id `
            -AzureDeviceId $device.azureADDeviceId `
            -LastActivity $device.lastSyncDateTime `
            -EnrollmentType $device.deviceEnrollmentType `
            -Ownership $device.managedDeviceOwnerType `
            -DeleteUri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($device.id)" `
            -Details "Agent: $($device.managementAgent); Direct managedDeviceId lookup"
    )
}

function ConvertTo-NormalizedMatchValue {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    return $Value.Trim().ToUpperInvariant()
}

function Get-LocalMatchingItem {
    param(
        [AllowNull()]
        [object]$Items,

        [Parameter(Mandatory)]
        [string]$SearchTerm,

        [Parameter(Mandatory)]
        [string[]]$PropertyNames
    )

    $normalizedSearchTerm = ConvertTo-NormalizedMatchValue -Value $SearchTerm
    if (-not $normalizedSearchTerm) {
        return @()
    }

    $exactMatches = New-Object System.Collections.Generic.List[object]
    $containsMatches = New-Object System.Collections.Generic.List[object]

    foreach ($item in (ConvertTo-ObjectArray -InputObject $Items)) {
        if (-not $item) {
            continue
        }

        $values = foreach ($propertyName in $PropertyNames) {
            $property = $item.PSObject.Properties[$propertyName]
            if ($property -and $property.Value) {
                ConvertTo-NormalizedMatchValue -Value ([string]$property.Value)
            }
        }

        $values = @($values | Where-Object { $_ })
        if (-not $values.Count) {
            continue
        }

        if ($values -contains $normalizedSearchTerm) {
            $item | Add-Member -MemberType NoteProperty -Name '_RdeMatchType' -Value 'Exact' -Force
            [void]$exactMatches.Add($item)
            continue
        }

        foreach ($value in $values) {
            if ($value.Contains($normalizedSearchTerm)) {
                $item | Add-Member -MemberType NoteProperty -Name '_RdeMatchType' -Value 'Partial' -Force
                [void]$containsMatches.Add($item)
                break
            }
        }
    }

    if ($exactMatches.Count -gt 0) {
        return $exactMatches
    }

    return $containsMatches
}

function Find-ManagedDeviceMatch {
    param(
        [Parameter(Mandatory)]
        [string]$SearchTerm
    )

    $escaped = ConvertTo-ODataString -Value $SearchTerm
    $select = "id,deviceName,serialNumber,userPrincipalName,operatingSystem,azureADDeviceId,managementAgent,lastSyncDateTime,deviceEnrollmentType,managedDeviceOwnerType"
    $uris = @(
        "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$escaped'&`$select=$select"
        "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=serialNumber eq '$escaped'&`$select=$select"
    )

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($uri in $uris) {
        foreach ($entry in (Invoke-GraphGetPaged -Uri $uri)) {
            [void]$items.Add($entry)
        }
    }

    $results = $items | ForEach-Object {
        ConvertTo-ResultObject -Source 'Intune Managed Device' `
            -DisplayName $_.deviceName `
            -SerialNumber $_.serialNumber `
            -PrimaryUser $_.userPrincipalName `
            -OperatingSystem $_.operatingSystem `
            -RecordId $_.id `
            -AzureDeviceId $_.azureADDeviceId `
            -LastActivity $_.lastSyncDateTime `
            -EnrollmentType $_.deviceEnrollmentType `
            -Ownership $_.managedDeviceOwnerType `
            -DeleteUri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($_.id)" `
            -Details "Agent: $($_.managementAgent)"
    }

    return Get-UniqueResultsByRecordId -Items @(ConvertTo-ObjectArray -InputObject $results)
}

function Find-EntraDeviceMatch {
    param(
        [Parameter(Mandatory)]
        [string]$SearchTerm
    )

    $escaped = ConvertTo-ODataString -Value $SearchTerm
    $deviceUri = "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$escaped'&`$select=id,displayName,deviceId,operatingSystem,approximateLastSignInDateTime"
    $items = Invoke-GraphGetPaged -Uri $deviceUri

    if ((Test-GuidString -Value $SearchTerm)) {
        $directDevice = Get-GraphObject -Uri "https://graph.microsoft.com/v1.0/devices(deviceId='$escaped')?`$select=id,displayName,deviceId,operatingSystem,approximateLastSignInDateTime"
        if ($directDevice) {
            $items.Add($directDevice)
        }
    }

    return $items | ForEach-Object {
        $lastSeen = if ($_.approximateLastSignInDateTime) { "Last sign-in: $($_.approximateLastSignInDateTime)" } else { 'Last sign-in: unknown' }
        ConvertTo-ResultObject -Source 'Entra ID Device' `
            -DisplayName $_.displayName `
            -SerialNumber '' `
            -PrimaryUser '' `
            -OperatingSystem $_.operatingSystem `
            -RecordId $_.id `
            -AzureDeviceId $_.deviceId `
            -LastActivity $_.approximateLastSignInDateTime `
            -DeleteUri "https://graph.microsoft.com/v1.0/devices/$($_.id)" `
            -Details $lastSeen
    }
}

function Find-EntraDeviceMatchByAzureDeviceId {
    param(
        [Parameter(Mandatory)]
        [string[]]$AzureDeviceIds
    )

    foreach ($azureDeviceId in ($AzureDeviceIds | Where-Object { $_ } | Sort-Object -Unique)) {
        $escaped = ConvertTo-ODataString -Value $azureDeviceId
        $device = Get-GraphObject -Uri "https://graph.microsoft.com/v1.0/devices(deviceId='$escaped')?`$select=id,displayName,deviceId,operatingSystem,approximateLastSignInDateTime"
        if (-not $device) {
            continue
        }

        $lastSeen = if ($device.approximateLastSignInDateTime) { "Last sign-in: $($device.approximateLastSignInDateTime)" } else { 'Last sign-in: unknown' }
        ConvertTo-ResultObject -Source 'Entra ID Device' `
            -DisplayName $device.displayName `
            -SerialNumber '' `
            -PrimaryUser '' `
            -OperatingSystem $device.operatingSystem `
            -RecordId $device.id `
            -AzureDeviceId $device.deviceId `
            -LastActivity $device.approximateLastSignInDateTime `
            -MatchType 'Linked' `
            -DeleteUri "https://graph.microsoft.com/v1.0/devices/$($device.id)" `
            -Details $lastSeen
    }
}

function Find-ManagedDeviceMatchFallback {
    param(
        [Parameter(Mandatory)]
        [string]$SearchTerm
    )

    $select = "id,deviceName,serialNumber,userPrincipalName,operatingSystem,azureADDeviceId,managementAgent,lastSyncDateTime,deviceEnrollmentType,managedDeviceOwnerType"
    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=$select"
    $items = Invoke-GraphGetPaged -Uri $uri
    $matchedItems = Get-LocalMatchingItem -Items $items -SearchTerm $SearchTerm -PropertyNames @('deviceName', 'serialNumber')

    $results = $matchedItems | ForEach-Object {
        $matchType = if ($_.PSObject.Properties['_RdeMatchType']) { [string]$_._RdeMatchType } else { 'Exact' }
        ConvertTo-ResultObject -Source 'Intune Managed Device' `
            -DisplayName $_.deviceName `
            -SerialNumber $_.serialNumber `
            -PrimaryUser $_.userPrincipalName `
            -OperatingSystem $_.operatingSystem `
            -RecordId $_.id `
            -AzureDeviceId $_.azureADDeviceId `
            -LastActivity $_.lastSyncDateTime `
            -EnrollmentType $_.deviceEnrollmentType `
            -Ownership $_.managedDeviceOwnerType `
            -MatchType $matchType `
            -DeleteUri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($_.id)" `
            -Details "Agent: $($_.managementAgent)"
    }

    return Get-UniqueResultsByRecordId -Items @(ConvertTo-ObjectArray -InputObject $results)
}

function Find-EntraDeviceMatchFallback {
    param(
        [Parameter(Mandatory)]
        [string]$SearchTerm
    )

    $select = "id,displayName,deviceId,operatingSystem,approximateLastSignInDateTime"
    $uri = "https://graph.microsoft.com/v1.0/devices?`$select=$select"
    $items = Invoke-GraphGetPaged -Uri $uri
    $matchedItems = Get-LocalMatchingItem -Items $items -SearchTerm $SearchTerm -PropertyNames @('displayName', 'deviceId')

    return $matchedItems | ForEach-Object {
        $lastSeen = if ($_.approximateLastSignInDateTime) { "Last sign-in: $($_.approximateLastSignInDateTime)" } else { 'Last sign-in: unknown' }
        $matchType = if ($_.PSObject.Properties['_RdeMatchType']) { [string]$_._RdeMatchType } else { 'Exact' }
        ConvertTo-ResultObject -Source 'Entra ID Device' `
            -DisplayName $_.displayName `
            -SerialNumber '' `
            -PrimaryUser '' `
            -OperatingSystem $_.operatingSystem `
            -RecordId $_.id `
            -AzureDeviceId $_.deviceId `
            -LastActivity $_.approximateLastSignInDateTime `
            -MatchType $matchType `
            -DeleteUri "https://graph.microsoft.com/v1.0/devices/$($_.id)" `
            -Details $lastSeen
    }
}

function Find-AutopilotMatch {
    param(
        [Parameter(Mandatory)]
        [string]$SearchTerm
    )

    $escaped = ConvertTo-ODataString -Value $SearchTerm
    $select = "id,displayName,serialNumber,manufacturer,model,azureActiveDirectoryDeviceId,lastContactedDateTime,enrollmentState"
    $uris = @(
        "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=serialNumber eq '$escaped'&`$select=$select"
        "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=displayName eq '$escaped'&`$select=$select"
    )

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($uri in $uris) {
        foreach ($entry in (Invoke-GraphGetPaged -Uri $uri)) {
            [void]$items.Add($entry)
        }
    }

    $results = $items | ForEach-Object {
        ConvertTo-ResultObject -Source 'Windows Autopilot' `
            -DisplayName $_.displayName `
            -SerialNumber $_.serialNumber `
            -PrimaryUser '' `
            -OperatingSystem '' `
            -RecordId $_.id `
            -AzureDeviceId $_.azureActiveDirectoryDeviceId `
            -LastActivity $_.lastContactedDateTime `
            -EnrollmentType $_.enrollmentState `
            -DeleteUri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$($_.id)" `
            -Details "$($_.manufacturer) $($_.model); Enrollment: $($_.enrollmentState)"
    }

    return Get-UniqueResultsByRecordId -Items @(ConvertTo-ObjectArray -InputObject $results)
}

function Find-AutopilotMatchFallback {
    param(
        [Parameter(Mandatory)]
        [string]$SearchTerm
    )

    $select = "id,displayName,serialNumber,manufacturer,model,azureActiveDirectoryDeviceId,lastContactedDateTime,enrollmentState"
    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$select=$select"
    $items = Invoke-GraphGetPaged -Uri $uri
    $matchedItems = Get-LocalMatchingItem -Items $items -SearchTerm $SearchTerm -PropertyNames @('displayName', 'serialNumber')

    $results = $matchedItems | ForEach-Object {
        $matchType = if ($_.PSObject.Properties['_RdeMatchType']) { [string]$_._RdeMatchType } else { 'Exact' }
        ConvertTo-ResultObject -Source 'Windows Autopilot' `
            -DisplayName $_.displayName `
            -SerialNumber $_.serialNumber `
            -PrimaryUser '' `
            -OperatingSystem '' `
            -RecordId $_.id `
            -AzureDeviceId $_.azureActiveDirectoryDeviceId `
            -LastActivity $_.lastContactedDateTime `
            -EnrollmentType $_.enrollmentState `
            -MatchType $matchType `
            -DeleteUri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$($_.id)" `
            -Details "$($_.manufacturer) $($_.model); Enrollment: $($_.enrollmentState)"
    }

    return Get-UniqueResultsByRecordId -Items @(ConvertTo-ObjectArray -InputObject $results)
}

function Search-DeviceEverywhere {
    param(
        [Parameter(Mandatory)]
        [string]$SearchTerm,

        [Parameter(Mandatory)]
        [System.Windows.Forms.TextBox]$LogTextBox,

        [ValidateSet('Intune', 'Autopilot', 'Entra')]
        [string[]]$Sources = @('Intune', 'Autopilot', 'Entra')
    )

    $script:CurrentSearchTerm = $SearchTerm
    $script:SearchResults.Clear()

    if ('Intune' -in $Sources) {
        Write-UiLog -TextBox $LogTextBox -Message "Searching for '$SearchTerm' in Intune managed devices..."
        [object[]]$managedMatches = @(Invoke-SearchBlock -Label 'Intune managed device search' -Action { Find-ManagedDeviceMatch -SearchTerm $SearchTerm } -LogTextBox $LogTextBox)
        if (-not $managedMatches.Count) {
            Write-UiLog -TextBox $LogTextBox -Message 'No exact Intune match from Graph. Running a local fallback scan; partial matches will be marked and excluded from Remove All.'
            [object[]]$managedMatches = @(Invoke-SearchBlock -Label 'Intune managed device fallback search' -Action { Find-ManagedDeviceMatchFallback -SearchTerm $SearchTerm } -LogTextBox $LogTextBox)
        }
        if (-not $managedMatches.Count) {
            Write-UiLog -TextBox $LogTextBox -Message 'No Intune match from name or serial. Trying direct managedDeviceId lookup from the search text...'
            [object[]]$managedMatches = @(Invoke-SearchBlock -Label 'Intune managed device ID lookup' -Action { Find-ManagedDeviceMatchByRecordId -SearchTerm $SearchTerm } -LogTextBox $LogTextBox)
        }
        Write-UiLog -TextBox $LogTextBox -Message "Intune managed device matches: $($managedMatches.Count)"
        foreach ($entry in $managedMatches) {
            [void]$script:SearchResults.Add($entry)
        }
    }

    if ('Autopilot' -in $Sources) {
        Write-UiLog -TextBox $LogTextBox -Message "Searching for '$SearchTerm' in Windows Autopilot..."
        [object[]]$autopilotMatches = @()
        $autopilotServiceUnavailable = $false

        try {
            [object[]]$autopilotMatches = @(Find-AutopilotMatch -SearchTerm $SearchTerm)
        }
        catch {
            if (Test-IsGraphInternalServerError -ErrorRecord $_) {
                $autopilotServiceUnavailable = $true
                Write-UiLog -TextBox $LogTextBox -Message 'Windows Autopilot search is temporarily unavailable because Microsoft Graph returned InternalServerError. Continuing without Autopilot results.'
            }
            else {
                Write-UiErrorDetail -TextBox $LogTextBox -Prefix 'Windows Autopilot search failed:' -ErrorRecord $_
            }
        }

        if (-not $autopilotMatches.Count -and -not $autopilotServiceUnavailable) {
            Write-UiLog -TextBox $LogTextBox -Message 'No exact Autopilot match from Graph. Running a local fallback scan; partial matches will be marked and excluded from Remove All.'
            try {
                [object[]]$autopilotMatches = @(Find-AutopilotMatchFallback -SearchTerm $SearchTerm)
            }
            catch {
                if (Test-IsGraphInternalServerError -ErrorRecord $_) {
                    Write-UiLog -TextBox $LogTextBox -Message 'Windows Autopilot fallback scan is temporarily unavailable because Microsoft Graph returned InternalServerError. Continuing without Autopilot results.'
                }
                else {
                    Write-UiErrorDetail -TextBox $LogTextBox -Prefix 'Windows Autopilot fallback search failed:' -ErrorRecord $_
                }
            }
        }
        Write-UiLog -TextBox $LogTextBox -Message "Windows Autopilot matches: $($autopilotMatches.Count)"
        foreach ($entry in $autopilotMatches) {
            [void]$script:SearchResults.Add($entry)
        }
    }

    if ('Entra' -in $Sources) {
        Write-UiLog -TextBox $LogTextBox -Message "Searching for '$SearchTerm' in Entra ID devices..."
        [object[]]$entraMatches = @(Invoke-SearchBlock -Label 'Entra ID search' -Action { Find-EntraDeviceMatch -SearchTerm $SearchTerm } -LogTextBox $LogTextBox)
        if (-not $entraMatches.Count) {
            Write-UiLog -TextBox $LogTextBox -Message 'No exact Entra match from Graph. Running a local fallback scan; partial matches will be marked and excluded from Remove All.'
            [object[]]$entraMatches = @(Invoke-SearchBlock -Label 'Entra ID fallback search' -Action { Find-EntraDeviceMatchFallback -SearchTerm $SearchTerm } -LogTextBox $LogTextBox)
        }
        Write-UiLog -TextBox $LogTextBox -Message "Entra ID matches: $($entraMatches.Count)"
        foreach ($entry in $entraMatches) {
            [void]$script:SearchResults.Add($entry)
        }
    }

    $linkedAzureDeviceIds = $script:SearchResults |
        Where-Object { $_.AzureDeviceId } |
        Select-Object -ExpandProperty AzureDeviceId -Unique

    if ('Entra' -in $Sources -and $linkedAzureDeviceIds) {
        Write-UiLog -TextBox $LogTextBox -Message 'Resolving linked Entra ID devices from Intune and Autopilot records...'
        [object[]]$linkedEntraMatches = @(Invoke-SearchBlock -Label 'Linked Entra ID resolution' -Action { Find-EntraDeviceMatchByAzureDeviceId -AzureDeviceIds $linkedAzureDeviceIds } -LogTextBox $LogTextBox)
        Write-UiLog -TextBox $LogTextBox -Message "Entra ID linked matches: $($linkedEntraMatches.Count)"
        foreach ($entry in $linkedEntraMatches) {
            [void]$script:SearchResults.Add($entry)
        }
    }

    $unique = $script:SearchResults |
        Sort-Object Source, RecordId -Unique

    $script:SearchResults.Clear()
    foreach ($entry in $unique) {
        [void]$script:SearchResults.Add($entry)
    }

    $partialCount = @($script:SearchResults | Where-Object { $_.MatchType -eq 'Partial' }).Count
    if ($partialCount -gt 0) {
        Write-UiLog -TextBox $LogTextBox -Message "$partialCount partial match(es) found. They require explicit row selection and are excluded from Remove All."
    }

    Write-UiLog -TextBox $LogTextBox -Message "Search completed. Found $($script:SearchResults.Count) matching record(s)."
    return $script:SearchResults
}

function Sort-RemovalPlan {
    param(
        [AllowNull()]
        [object]$Records
    )

    $items = ConvertTo-ObjectArray -InputObject $Records
    $ordered = $items | Sort-Object `
        @{ Expression = {
            switch ($_.Source) {
                'Intune Managed Device' { 10 }
                'Windows Autopilot' { 20 }
                'Entra ID Device' { 30 }
                default { 40 }
            }
        } }, `
        Source, RecordId

    return $ordered
}

function Resolve-RemovalPlan {
    param(
        [Parameter(Mandatory)]
        [object[]]$SeedRecords,

        [Parameter(Mandatory)]
        [System.Collections.Generic.List[object]]$AllRecords,

        [Parameter(Mandatory)]
        [bool]$ExpandLinked,

        [bool]$IncludePartial = $true
    )

    $eligibleSeeds = @($SeedRecords | Where-Object {
        $_ -and ($IncludePartial -or -not $_.PSObject.Properties['MatchType'] -or $_.MatchType -ne 'Partial')
    })

    if ($ExpandLinked) {
        $expanded = Get-LinkedRecord -SeedRecords $eligibleSeeds -AllRecords $AllRecords
        if (-not $IncludePartial) {
            $expanded = @($expanded | Where-Object { -not $_.PSObject.Properties['MatchType'] -or $_.MatchType -ne 'Partial' })
        }
        return Sort-RemovalPlan -Records $expanded
    }

    $unique = New-Object System.Collections.Generic.List[object]
    $seenRecordIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($record in $eligibleSeeds) {
        if (-not $record) {
            continue
        }

        $key = "$($record.Source)|$($record.RecordId)"
        if ($seenRecordIds.Add($key)) {
            [void]$unique.Add($record)
        }
    }

    return Sort-RemovalPlan -Records $unique
}

function Get-LinkedRecord {
    param(
        [Parameter(Mandatory)]
        [object[]]$SeedRecords,

        [Parameter(Mandatory)]
        [System.Collections.Generic.List[object]]$AllRecords
    )

    $expanded = New-Object System.Collections.Generic.List[object]
    $queue = New-Object System.Collections.Generic.Queue[object]
    $seenRecordIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $seenKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($record in $SeedRecords) {
        if ($record -and $seenRecordIds.Add("$($record.Source)|$($record.RecordId)")) {
            $queue.Enqueue($record)
        }
    }

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        [void]$expanded.Add($current)

        $keyA = ConvertTo-NormalizedMatchValue -Value $current.AzureDeviceId
        $keyB = ConvertTo-NormalizedMatchValue -Value $current.SerialNumber
        if ($keyA) { [void]$seenKeys.Add($keyA) }
        if ($keyB) { [void]$seenKeys.Add($keyB) }

        foreach ($candidate in $AllRecords) {
            $candidateId = "$($candidate.Source)|$($candidate.RecordId)"
            if ($seenRecordIds.Contains($candidateId)) {
                continue
            }

            $ckA = ConvertTo-NormalizedMatchValue -Value $candidate.AzureDeviceId
            $ckB = ConvertTo-NormalizedMatchValue -Value $candidate.SerialNumber
            $candidateKeys = New-Object System.Collections.Generic.List[string]
            if ($ckA) { [void]$candidateKeys.Add($ckA) }
            if ($ckB) { [void]$candidateKeys.Add($ckB) }

            $isLinked = $false
            foreach ($candidateKey in $candidateKeys) {
                if ($seenKeys.Contains($candidateKey)) {
                    $isLinked = $true
                    break
                }
            }

            if (-not $isLinked) {
                continue
            }

            [void]$seenRecordIds.Add($candidateId)
            $queue.Enqueue($candidate)
        }
    }

    return $expanded
}

function Invoke-AutopilotAssignmentLinkRemoval {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Record,

        [Parameter(Mandatory)]
        [System.Windows.Forms.TextBox]$LogTextBox
    )

    $assignmentUri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities/$($Record.RecordId)/deploymentProfile/assignedDevices/$($Record.RecordId)"

    try {
        if (-not $PSCmdlet.ShouldProcess($Record.DisplayName, 'Remove Autopilot deployment assignment link')) {
            Write-UiLog -TextBox $LogTextBox -Message "Skipped Autopilot assignment cleanup for $($Record.DisplayName): WhatIf/Confirm prevented the action."
            return
        }

        Invoke-DeviceCleanupGraphRequest -Method DELETE -Uri $assignmentUri | Out-Null
        Write-UiLog -TextBox $LogTextBox -Message "Removed Autopilot deployment assignment for $($Record.DisplayName)."
    }
    catch {
        Write-UiLog -TextBox $LogTextBox -Message "Skipped Autopilot deployment assignment cleanup for $($Record.DisplayName): $($_.Exception.Message)"
    }
}

function Invoke-DeviceRecordRemoval {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Record,

        [Parameter(Mandatory)]
        [System.Windows.Forms.TextBox]$LogTextBox
    )

    Write-UiLog -TextBox $LogTextBox -Message "Deleting $($Record.Source): $($Record.DisplayName) [$($Record.RecordId)]"
    if (-not $PSCmdlet.ShouldProcess("$($Record.Source): $($Record.DisplayName)", 'Delete device record')) {
        Write-UiLog -TextBox $LogTextBox -Message "Skipped $($Record.Source): $($Record.DisplayName) due to WhatIf/Confirm."
        return 'Skipped'
    }

    if ($Record.Source -eq 'Windows Autopilot') {
        Invoke-AutopilotAssignmentLinkRemoval -Record $Record -LogTextBox $LogTextBox
    }

    try {
        Invoke-DeviceCleanupGraphRequest -Method DELETE -Uri $Record.DeleteUri | Out-Null
    }
    catch {
        if ($_.Exception.Message -match '404|NotFound') {
            Write-UiLog -TextBox $LogTextBox -Message "$($Record.Source) already absent on delete call: $($Record.DisplayName)"
            return 'AlreadyAbsent'
        }

        throw
    }

    if (-not (Confirm-GraphDeletion -Uri $Record.DeleteUri)) {
        Write-UiLog -TextBox $LogTextBox -Message "Delete accepted for $($Record.Source): $($Record.DisplayName), but the record is still visible. Marked Pending for later verification."
        return 'Pending'
    }

    Write-UiLog -TextBox $LogTextBox -Message "Deleted $($Record.Source): $($Record.DisplayName) (verified)"
    return 'Deleted'
}

function Sync-GridData {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.DataGridView]$Grid,

        [Parameter()]
        [AllowNull()]
        [object]$Records = $script:SearchResults
    )

    # PS 5.1 binder can trigger PropertyNotFoundStrict internally on .Count during WinForms overload binding.
    # Keep strict mode off in this function scope so grid row operations remain stable.
    Set-StrictMode -Off

    if (-not $PSCmdlet.ShouldProcess('UI Grid', 'Sync grid data')) {
        return
    }

    $recordItems = New-Object System.Collections.Generic.List[object]
    if ($null -ne $Records) {
        if ($Records -is [string] -or $Records -isnot [System.Collections.IEnumerable]) {
            [void]$recordItems.Add($Records)
        }
        else {
            foreach ($item in $Records) {
                [void]$recordItems.Add($item)
            }
        }
    }

    $Grid.DataSource = $null
    $Grid.Rows.Clear()
    $Grid.Columns.Clear()

    $columnDefinitions = @(
        @('MatchType', 'Match')
        @('InputTerm', 'Input term')
        @('Source', 'Source')
        @('DisplayName', 'Display name')
        @('SerialNumber', 'Serial number')
        @('OperatingSystem', 'OS')
        @('LastActivity', 'Last activity')
        @('ExpectedAction', 'Expected action')
        @('ResultStatus', 'Status')
        @('PrimaryUser', 'Primary user')
        @('EnrollmentType', 'Enrollment')
        @('Ownership', 'Ownership')
        @('RecordId', 'Record ID')
        @('AzureDeviceId', 'Azure device ID')
        @('DeleteUri', 'Delete URI')
        @('Details', 'Details')
    )

    foreach ($columnDefinition in $columnDefinitions) {
        [void]$Grid.Columns.Add([string]$columnDefinition[0], [string]$columnDefinition[1])
    }

    $rowsToAdd = New-Object 'System.Collections.Generic.List[System.Windows.Forms.DataGridViewRow]'

    foreach ($item in $recordItems) {
        $row = New-Object System.Windows.Forms.DataGridViewRow
        $row.CreateCells($Grid)
        for ($columnIndex = 0; $columnIndex -lt $columnDefinitions.Count; $columnIndex++) {
            $propertyName = [string]$columnDefinitions[$columnIndex][0]
            $property = if ($item) { $item.PSObject.Properties[$propertyName] } else { $null }
            $row.Cells[$columnIndex].Value = if ($property -and $null -ne $property.Value) { [string]$property.Value } else { '' }
        }

        if ($item -and $item.MatchType -eq 'Partial') {
            $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 248, 220)
        }
        elseif ($item -and $item.ResultStatus -eq 'Failed') {
            $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 230, 230)
        }
        elseif ($item -and $item.ResultStatus -eq 'Pending') {
            $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 244, 204)
        }
        $row.Tag = $item
        [void]$rowsToAdd.Add($row)
    }

    if ($rowsToAdd.Count -gt 0) {
        $Grid.Rows.AddRange($rowsToAdd.ToArray())
    }
    foreach ($column in $Grid.Columns) {
        $column.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::Automatic
    }

    if ($Grid.Columns['DeleteUri']) {
        $Grid.Columns['DeleteUri'].Visible = $false
    }

    if ($Grid.Columns['RecordId']) {
        $Grid.Columns['RecordId'].Width = 230
    }

    if ($Grid.Columns['DisplayName']) {
        $Grid.Columns['DisplayName'].Width = 165
    }

    if ($Grid.Columns['Details']) {
        $Grid.Columns['Details'].Width = 180
    }

    if ($Grid.Columns['Source']) {
        $Grid.Columns['Source'].Width = 150
    }

    if ($Grid.Columns['ExpectedAction']) {
        $Grid.Columns['ExpectedAction'].Width = 210
    }

    if ($Grid.Columns['LastActivity']) {
        $Grid.Columns['LastActivity'].Width = 165
    }

    if ($Grid.Columns['SerialNumber']) {
        $Grid.Columns['SerialNumber'].Width = 130
    }
}

function Get-SelectedRecord {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.DataGridView]$Grid
    )

    $selected = New-Object System.Collections.Generic.List[object]

    foreach ($row in $Grid.SelectedRows) {
        if ($row.Tag) {
            [void]$selected.Add($row.Tag)
            continue
        }

        if ($row.DataBoundItem) {
            [void]$selected.Add($row.DataBoundItem)
        }
    }

    return $selected
}

function Sync-PreviewData {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.DataGridView]$SourceGrid,

        [Parameter(Mandatory)]
        [System.Windows.Forms.DataGridView]$PreviewGrid,

        [Parameter(Mandatory)]
        [System.Windows.Forms.Label]$PreviewLabel,

        [Parameter(Mandatory)]
        [bool]$ExpandLinked
    )

    Set-StrictMode -Off

    if (-not $PSCmdlet.ShouldProcess('UI Preview', 'Sync preview data')) {
        return
    }

    $script:PreviewResults.Clear()
    $selected = Get-SelectedRecord -Grid $SourceGrid

    if (-not $selected.Count) {
        Sync-GridData -Grid $PreviewGrid -Records $null
        $PreviewLabel.Text = 'Removal Preview: Select one or more results to see exactly what will be deleted'
        return
    }

    $plannedRecords = Resolve-RemovalPlan -SeedRecords $selected -AllRecords $script:SearchResults -ExpandLinked:$ExpandLinked
    foreach ($record in $plannedRecords) {
        [void]$script:PreviewResults.Add($record)
    }

    Sync-GridData -Grid $PreviewGrid -Records $script:PreviewResults
    if ($ExpandLinked) {
        $PreviewLabel.Text = "Removal Preview: $($script:PreviewResults.Count) record(s) will be deleted including linked matches"
        return
    }

    $PreviewLabel.Text = "Removal Preview: $($script:PreviewResults.Count) selected record(s) will be deleted"
}

function Invoke-RemovalPlan {
    param(
        [Parameter(Mandatory)]
        [object[]]$Records,

        [Parameter(Mandatory)]
        [System.Windows.Forms.TextBox]$LogTextBox
    )

    $deletedCount = 0
    $failedCount = 0
    $pendingCount = 0
    $skippedCount = 0
    $outcomes = New-Object System.Collections.Generic.List[object]
    $successfulRecordKeys = New-Object System.Collections.Generic.List[string]

    foreach ($record in (Sort-RemovalPlan -Records $Records)) {
        try {
            $removalState = Invoke-DeviceRecordRemoval -Record $record -LogTextBox $LogTextBox
            $record.ResultStatus = $removalState

            if ($removalState -in @('Deleted', 'AlreadyAbsent')) {
                [void]$script:SearchResults.Remove($record)
                [void]$successfulRecordKeys.Add("$($record.Source)|$($record.RecordId)")
                if ($removalState -eq 'AlreadyAbsent') {
                    Write-AuditEntry -Record $record -Outcome 'AlreadyAbsent' -Message 'Record was already absent when delete was attempted.'
                }
                else {
                    Write-AuditEntry -Record $record -Outcome 'Deleted' -Message 'Record deleted successfully and verified absent.'
                }
                $deletedCount++
            }
            elseif ($removalState -eq 'Pending') {
                Write-AuditEntry -Record $record -Outcome 'Pending' -Message 'Delete was accepted but the record was still visible during verification.'
                $pendingCount++
            }
            else {
                Write-AuditEntry -Record $record -Outcome 'Skipped' -Message 'Removal was skipped before a delete request was sent.'
                $skippedCount++
            }

            [void]$outcomes.Add([PSCustomObject]@{ Record = $record; Outcome = $removalState })
        }
        catch {
            $message = Get-ExceptionSummary -ErrorRecord $_
            $record.ResultStatus = 'Failed'
            Write-UiErrorDetail -TextBox $LogTextBox -Prefix "Deletion failed for $($record.Source): $($record.DisplayName):" -ErrorRecord $_
            Write-AuditEntry -Record $record -Outcome 'Failed' -Message $message
            $failedCount++
            [void]$outcomes.Add([PSCustomObject]@{ Record = $record; Outcome = 'Failed' })
        }
    }

    return [PSCustomObject]@{
        DeletedCount        = $deletedCount
        FailedCount         = $failedCount
        PendingCount        = $pendingCount
        SkippedCount        = $skippedCount
        SuccessfulRecordKeys = $successfulRecordKeys.ToArray()
        Outcomes            = $outcomes.ToArray()
    }
}

if ($NoGui) {
    return
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Remove Device Everywhere v$script:AppVersion"
$form.Size = New-Object System.Drawing.Size(1260, 820)
$form.MinimumSize = New-Object System.Drawing.Size(900, 600)
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

# MenuStrip definitions
$menuStrip = New-Object System.Windows.Forms.MenuStrip
$menuStrip.Dock = 'Fill'

$fileMenu = New-Object System.Windows.Forms.ToolStripMenuItem('&File')
$fileLoadBulkInputMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('Load &Bulk Input...')
$fileLoadBulkInputMenuItem.ShortcutKeys = [System.Windows.Forms.Keys]::Control -bor [System.Windows.Forms.Keys]::O
$fileExportCurrentLogMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('&Export Current Log...')
$fileExportCurrentLogMenuItem.ShortcutKeys = [System.Windows.Forms.Keys]::Control -bor [System.Windows.Forms.Keys]::S
$fileOpenAuditFolderMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('Open Audit &Folder')
$fileOpenAuditCsvMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('Open Current Audit &CSV')
$fileExitMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('E&xit')
$fileMenu.DropDownItems.AddRange(@(
    $fileLoadBulkInputMenuItem,
    $fileExportCurrentLogMenuItem,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $fileOpenAuditFolderMenuItem,
    $fileOpenAuditCsvMenuItem,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $fileExitMenuItem
))

$toolsMenu = New-Object System.Windows.Forms.ToolStripMenuItem('&Tools')
$toolsConnectMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('&Connect Graph')
$toolsClearSingleMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('Clear &Single Tab')
$toolsClearBulkMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('Clear &Bulk Tab')
$toolsMenu.DropDownItems.AddRange(@(
    $toolsConnectMenuItem,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $toolsClearSingleMenuItem,
    $toolsClearBulkMenuItem
))

$helpMenu = New-Object System.Windows.Forms.ToolStripMenuItem('&Help')
$helpGithubMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('&GitHub Repository')
$helpAboutMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('&About')
$helpMenu.DropDownItems.AddRange(@(
    $helpGithubMenuItem,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $helpAboutMenuItem
))

[void]$menuStrip.Items.Add($fileMenu)
[void]$menuStrip.Items.Add($toolsMenu)
[void]$menuStrip.Items.Add($helpMenu)
$form.MainMenuStrip = $menuStrip

# Outer TableLayoutPanel: 4 rows (menu / title / connect bar / tabs)
$formLayout = New-Object System.Windows.Forms.TableLayoutPanel
$formLayout.Dock = 'Fill'
$formLayout.ColumnCount = 1
$formLayout.RowCount = 4
[void]$formLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$formLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 28)))
[void]$formLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 48)))
[void]$formLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 52)))
[void]$formLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$formLayout.Padding = New-Object System.Windows.Forms.Padding(0)
$formLayout.Margin  = New-Object System.Windows.Forms.Padding(0)
$form.Controls.Add($formLayout)

# Row 0: menustrip
$menuPanel = New-Object System.Windows.Forms.Panel
$menuPanel.Dock = 'Fill'
$menuPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$menuPanel.Controls.Add($menuStrip)
$formLayout.Controls.Add($menuPanel, 0, 0)

# Row 1: title
$titlePanel = New-Object System.Windows.Forms.Panel
$titlePanel.Dock = 'Fill'
$titlePanel.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
$titlePanel.Margin = New-Object System.Windows.Forms.Padding(0)
$formLayout.Controls.Add($titlePanel, 0, 1)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Dock = 'Fill'
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
$titleLabel.Text = "Remove Device Everywhere v$script:AppVersion  |  Safe Cleanup"
$titleLabel.TextAlign = 'MiddleLeft'
$titleLabel.Padding = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
$titlePanel.Controls.Add($titleLabel)

# Row 2: connect bar
$connectBarPanel = New-Object System.Windows.Forms.Panel
$connectBarPanel.Dock = 'Fill'
$connectBarPanel.BackColor = [System.Drawing.Color]::FromArgb(230, 233, 240)
$connectBarPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$formLayout.Controls.Add($connectBarPanel, 0, 2)

$connectButton = New-Object System.Windows.Forms.Button
$connectButton.Location = New-Object System.Drawing.Point(12, 9)
$connectButton.Size = New-Object System.Drawing.Size(140, 34)
$connectButton.Text = 'Connect Graph'
$connectButton.Anchor = 'Left,Top'
$connectBarPanel.Controls.Add($connectButton)

$deviceCodeCheckBox = New-Object System.Windows.Forms.CheckBox
$deviceCodeCheckBox.Location = New-Object System.Drawing.Point(162, 15)
$deviceCodeCheckBox.Size = New-Object System.Drawing.Size(286, 22)
$deviceCodeCheckBox.Checked = $false
$deviceCodeCheckBox.Text = 'Use device code sign-in instead of popup (advanced)'
$deviceCodeCheckBox.Anchor = 'Left,Top'
$connectBarPanel.Controls.Add($deviceCodeCheckBox)
$deviceCodeCheckBox.Visible = $false

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(162, 16)
$statusLabel.Size = New-Object System.Drawing.Size(1070, 20)
$statusLabel.Text = 'Status: Not connected'
$statusLabel.Anchor = 'Left,Right,Top'
$connectBarPanel.Controls.Add($statusLabel)

# Row 3: TabControl (Dock=Fill, scales with window)
$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Dock = 'Fill'
$tabControl.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$tabControl.Margin = New-Object System.Windows.Forms.Padding(0)
$formLayout.Controls.Add($tabControl, 0, 3)

# 
# TAB 1 - Single device search
# 
$tab1 = New-Object System.Windows.Forms.TabPage
$tab1.Text = '  Single Device Search  '
$tab1.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
$tab1.Padding = New-Object System.Windows.Forms.Padding(0)
$tabControl.TabPages.Add($tab1)

# Tab1 inner layout: 7 rows with percentage heights for grids/log
$tab1Layout = New-Object System.Windows.Forms.TableLayoutPanel
$tab1Layout.Dock = 'Fill'
$tab1Layout.ColumnCount = 1
$tab1Layout.RowCount = 7
[void]$tab1Layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$tab1Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 58)))   # search bar
[void]$tab1Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30)))   # checkbox
[void]$tab1Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 48)))    # results grid
[void]$tab1Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))   # preview label
[void]$tab1Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 22)))    # preview grid
[void]$tab1Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))   # log label
[void]$tab1Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 30)))    # log textbox
$tab1Layout.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)
$tab1Layout.Margin  = New-Object System.Windows.Forms.Padding(0)
$tab1.Controls.Add($tab1Layout)

# Row 0: search bar
$searchPanel = New-Object System.Windows.Forms.Panel
$searchPanel.Dock = 'Fill'
$searchPanel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
$tab1Layout.Controls.Add($searchPanel, 0, 0)

$searchLabel = New-Object System.Windows.Forms.Label
$searchLabel.Text = 'Device name or serial number'
$searchLabel.Location = New-Object System.Drawing.Point(0, 2)
$searchLabel.AutoSize = $true
$searchLabel.Anchor = 'Left,Top'
$searchPanel.Controls.Add($searchLabel)

$searchTextBox = New-Object System.Windows.Forms.TextBox
$searchTextBox.Location = New-Object System.Drawing.Point(0, 22)
$searchTextBox.Height = 28
$searchTextBox.Font = New-Object System.Drawing.Font('Segoe UI', 11)
$searchTextBox.Anchor = 'Left,Right,Top'
$searchPanel.Controls.Add($searchTextBox)

$clearButton = New-Object System.Windows.Forms.Button
$clearButton.Size = New-Object System.Drawing.Size(90, 30)
$clearButton.Text = 'Clear'
$clearButton.Anchor = 'Right,Top'
$searchPanel.Controls.Add($clearButton)

$selectAllButton = New-Object System.Windows.Forms.Button
$selectAllButton.Size = New-Object System.Drawing.Size(100, 30)
$selectAllButton.Text = 'Select All'
$selectAllButton.Enabled = $false
$selectAllButton.Anchor = 'Right,Top'
$searchPanel.Controls.Add($selectAllButton)

$removeAllButton = New-Object System.Windows.Forms.Button
$removeAllButton.Size = New-Object System.Drawing.Size(130, 30)
$removeAllButton.Text = 'Remove Exact Found'
$removeAllButton.Enabled = $false
$removeAllButton.Anchor = 'Right,Top'
$searchPanel.Controls.Add($removeAllButton)

$removeButton = New-Object System.Windows.Forms.Button
$removeButton.Size = New-Object System.Drawing.Size(150, 30)
$removeButton.Text = 'Remove Selected'
$removeButton.Enabled = $false
$removeButton.Anchor = 'Right,Top'
$searchPanel.Controls.Add($removeButton)

$searchButton = New-Object System.Windows.Forms.Button
$searchButton.Size = New-Object System.Drawing.Size(100, 30)
$searchButton.Text = 'Search'
$searchButton.Enabled = $false
$searchButton.Anchor = 'Right,Top'
$searchPanel.Controls.Add($searchButton)

# Lay out buttons right-to-left; textbox fills remaining left space
$positionTab1Controls = {
    $w = $searchPanel.ClientSize.Width
    $btnY = 20
    $gap  = 6
    $rC   = $w - 4
    $clearButton.Location     = New-Object System.Drawing.Point(($rC - $clearButton.Width), $btnY)
    $rC -= $clearButton.Width + $gap
    $selectAllButton.Location = New-Object System.Drawing.Point(($rC - $selectAllButton.Width), $btnY)
    $rC -= $selectAllButton.Width + $gap
    $removeAllButton.Location = New-Object System.Drawing.Point(($rC - $removeAllButton.Width), $btnY)
    $rC -= $removeAllButton.Width + $gap
    $removeButton.Location    = New-Object System.Drawing.Point(($rC - $removeButton.Width), $btnY)
    $rC -= $removeButton.Width + $gap
    $searchButton.Location    = New-Object System.Drawing.Point(($rC - $searchButton.Width), $btnY)
    $searchTextBox.Width      = $searchButton.Left - $gap
}
$searchPanel.Add_Resize($positionTab1Controls)
$searchPanel.Add_Layout($positionTab1Controls)

# Row 1: source and safety options
$singleOptionsPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$singleOptionsPanel.Dock = 'Fill'
$singleOptionsPanel.WrapContents = $false
$singleOptionsPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$tab1Layout.Controls.Add($singleOptionsPanel, 0, 1)

$intuneSourceCheckBox = New-Object System.Windows.Forms.CheckBox
$intuneSourceCheckBox.Text = 'Intune'
$intuneSourceCheckBox.Checked = $true
$intuneSourceCheckBox.AutoSize = $true
$singleOptionsPanel.Controls.Add($intuneSourceCheckBox)

$autopilotSourceCheckBox = New-Object System.Windows.Forms.CheckBox
$autopilotSourceCheckBox.Text = 'Autopilot'
$autopilotSourceCheckBox.Checked = $true
$autopilotSourceCheckBox.AutoSize = $true
$singleOptionsPanel.Controls.Add($autopilotSourceCheckBox)

$entraSourceCheckBox = New-Object System.Windows.Forms.CheckBox
$entraSourceCheckBox.Text = 'Entra ID'
$entraSourceCheckBox.Checked = $true
$entraSourceCheckBox.AutoSize = $true
$singleOptionsPanel.Controls.Add($entraSourceCheckBox)

$linkedCleanupCheckBox = New-Object System.Windows.Forms.CheckBox
$linkedCleanupCheckBox.Text = 'Expand selected rows to linked serial/Azure device ID records'
$linkedCleanupCheckBox.Checked = $false
$linkedCleanupCheckBox.AutoSize = $true
$linkedCleanupCheckBox.Margin = New-Object System.Windows.Forms.Padding(18, 3, 0, 0)
$singleOptionsPanel.Controls.Add($linkedCleanupCheckBox)

# Row 2: results grid (48% of variable height)
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.BackgroundColor = [System.Drawing.Color]::White
$grid.BorderStyle = 'FixedSingle'
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $true
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AutoSizeRowsMode = 'DisplayedCells'
$grid.AutoGenerateColumns = $true
$grid.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
$tab1Layout.Controls.Add($grid, 0, 2)

# Row 3: preview label
$previewLabel = New-Object System.Windows.Forms.Label
$previewLabel.Text = 'Removal Preview: Select one or more results to see exactly what will be deleted'
$previewLabel.Dock = 'Fill'
$previewLabel.TextAlign = 'MiddleLeft'
$previewLabel.Margin = New-Object System.Windows.Forms.Padding(0)
$tab1Layout.Controls.Add($previewLabel, 0, 3)

# Row 4: preview grid (22% of variable height)
$previewGrid = New-Object System.Windows.Forms.DataGridView
$previewGrid.Dock = 'Fill'
$previewGrid.BackgroundColor = [System.Drawing.Color]::White
$previewGrid.BorderStyle = 'FixedSingle'
$previewGrid.SelectionMode = 'FullRowSelect'
$previewGrid.MultiSelect = $false
$previewGrid.ReadOnly = $true
$previewGrid.AllowUserToAddRows = $false
$previewGrid.AllowUserToDeleteRows = $false
$previewGrid.AutoSizeRowsMode = 'DisplayedCells'
$previewGrid.AutoGenerateColumns = $true
$previewGrid.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
$tab1Layout.Controls.Add($previewGrid, 0, 4)

# Row 5: log label
$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = 'Activity log'
$logLabel.Dock = 'Fill'
$logLabel.TextAlign = 'MiddleLeft'
$logLabel.Margin = New-Object System.Windows.Forms.Padding(0)
$tab1Layout.Controls.Add($logLabel, 0, 5)

# Row 6: log textbox (30% of variable height)
$logTextBox = New-Object System.Windows.Forms.TextBox
$logTextBox.Dock = 'Fill'
$logTextBox.Multiline = $true
$logTextBox.ScrollBars = 'Vertical'
$logTextBox.ReadOnly = $true
$logTextBox.Font = New-Object System.Drawing.Font('Consolas', 10)
$logTextBox.Margin = New-Object System.Windows.Forms.Padding(0)
$tab1Layout.Controls.Add($logTextBox, 0, 6)

# 
# TAB 2 - Bulk Operations
# 
$tab2 = New-Object System.Windows.Forms.TabPage
$tab2.Text = '  Bulk Operations  '
$tab2.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
$tab2.Padding = New-Object System.Windows.Forms.Padding(0)
$tabControl.TabPages.Add($tab2)

# Tab2 inner layout: 5 rows with percentage heights for grid/log
$tab2Layout = New-Object System.Windows.Forms.TableLayoutPanel
$tab2Layout.Dock = 'Fill'
$tab2Layout.ColumnCount = 1
$tab2Layout.RowCount = 5
[void]$tab2Layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$tab2Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 220)))  # input area
[void]$tab2Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))   # results label
[void]$tab2Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 60)))    # bulk grid
[void]$tab2Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))   # log label
[void]$tab2Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 40)))    # log textbox
$tab2Layout.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)
$tab2Layout.Margin  = New-Object System.Windows.Forms.Padding(0)
$tab2.Controls.Add($tab2Layout)

# Row 0: input panel
$bulkInputPanel = New-Object System.Windows.Forms.TableLayoutPanel
$bulkInputPanel.Dock = 'Fill'
$bulkInputPanel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
$bulkInputPanel.ColumnCount = 1
$bulkInputPanel.RowCount = 2
[void]$bulkInputPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$bulkInputPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))
[void]$bulkInputPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$tab2Layout.Controls.Add($bulkInputPanel, 0, 0)

$bulkInputLabel = New-Object System.Windows.Forms.Label
$bulkInputLabel.Text = 'Device names / serial numbers (one per line)  --  or load a CSV / TXT file'
$bulkInputLabel.Dock = 'Fill'
$bulkInputLabel.TextAlign = 'MiddleLeft'
$bulkInputLabel.Margin = New-Object System.Windows.Forms.Padding(0)
$bulkInputPanel.Controls.Add($bulkInputLabel, 0, 0)

$bulkInputContentLayout = New-Object System.Windows.Forms.TableLayoutPanel
$bulkInputContentLayout.Dock = 'Fill'
$bulkInputContentLayout.ColumnCount = 2
$bulkInputContentLayout.RowCount = 1
[void]$bulkInputContentLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$bulkInputContentLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 340)))
[void]$bulkInputContentLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$bulkInputContentLayout.Margin = New-Object System.Windows.Forms.Padding(0)
$bulkInputPanel.Controls.Add($bulkInputContentLayout, 0, 1)

$bulkInputTextBox = New-Object System.Windows.Forms.TextBox
$bulkInputTextBox.Dock = 'Fill'
$bulkInputTextBox.Multiline = $true
$bulkInputTextBox.ScrollBars = 'Vertical'
$bulkInputTextBox.Font = New-Object System.Drawing.Font('Consolas', 10)
$bulkInputTextBox.AcceptsReturn = $true
$bulkInputTextBox.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$bulkInputContentLayout.Controls.Add($bulkInputTextBox, 0, 0)

$bulkRightLayout = New-Object System.Windows.Forms.TableLayoutPanel
$bulkRightLayout.Dock = 'Fill'
$bulkRightLayout.ColumnCount = 2
$bulkRightLayout.RowCount = 6
[void]$bulkRightLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 160)))
[void]$bulkRightLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 160)))
[void]$bulkRightLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
[void]$bulkRightLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
[void]$bulkRightLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
[void]$bulkRightLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
[void]$bulkRightLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30)))
[void]$bulkRightLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$bulkRightLayout.Margin = New-Object System.Windows.Forms.Padding(0)
$bulkInputContentLayout.Controls.Add($bulkRightLayout, 1, 0)

$bulkSearchButton = New-Object System.Windows.Forms.Button
$bulkSearchButton.Dock = 'Fill'
$bulkSearchButton.Text = 'Search All'
$bulkSearchButton.Enabled = $false
$bulkSearchButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 4)
$bulkRightLayout.Controls.Add($bulkSearchButton, 0, 0)

$bulkLoadFileButton = New-Object System.Windows.Forms.Button
$bulkLoadFileButton.Dock = 'Fill'
$bulkLoadFileButton.Text = 'Load CSV / TXT...'
$bulkLoadFileButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
$bulkRightLayout.Controls.Add($bulkLoadFileButton, 1, 0)

$bulkRemoveAllButton = New-Object System.Windows.Forms.Button
$bulkRemoveAllButton.Dock = 'Fill'
$bulkRemoveAllButton.Text = 'Remove Exact Found'
$bulkRemoveAllButton.Enabled = $false
$bulkRemoveAllButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
$bulkRightLayout.Controls.Add($bulkRemoveAllButton, 1, 1)

$bulkRemoveSelectedButton = New-Object System.Windows.Forms.Button
$bulkRemoveSelectedButton.Dock = 'Fill'
$bulkRemoveSelectedButton.Text = 'Remove Selected'
$bulkRemoveSelectedButton.Enabled = $false
$bulkRemoveSelectedButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 4)
$bulkRightLayout.Controls.Add($bulkRemoveSelectedButton, 0, 1)

$bulkCsvColumnLabel = New-Object System.Windows.Forms.Label
$bulkCsvColumnLabel.Text = 'CSV column name:'
$bulkCsvColumnLabel.Dock = 'Fill'
$bulkCsvColumnLabel.TextAlign = 'BottomLeft'
$bulkCsvColumnLabel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 0)
$bulkRightLayout.Controls.Add($bulkCsvColumnLabel, 0, 3)

$bulkClearButton = New-Object System.Windows.Forms.Button
$bulkClearButton.Dock = 'Fill'
$bulkClearButton.Text = 'Clear'
$bulkClearButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
$bulkRightLayout.Controls.Add($bulkClearButton, 1, 2)

$bulkExportPlanButton = New-Object System.Windows.Forms.Button
$bulkExportPlanButton.Dock = 'Fill'
$bulkExportPlanButton.Text = 'Export Dry Run...'
$bulkExportPlanButton.Enabled = $false
$bulkExportPlanButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 4)
$bulkRightLayout.Controls.Add($bulkExportPlanButton, 0, 2)

$bulkCsvColumnTextBox = New-Object System.Windows.Forms.TextBox
$bulkCsvColumnTextBox.Dock = 'Fill'
$bulkCsvColumnTextBox.Text = 'DeviceName'
$bulkCsvColumnTextBox.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
$bulkRightLayout.Controls.Add($bulkCsvColumnTextBox, 1, 3)

$bulkSourceOptionsPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$bulkSourceOptionsPanel.Dock = 'Fill'
$bulkSourceOptionsPanel.WrapContents = $false
$bulkSourceOptionsPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$bulkRightLayout.SetColumnSpan($bulkSourceOptionsPanel, 2)
$bulkRightLayout.Controls.Add($bulkSourceOptionsPanel, 0, 4)

$bulkIntuneSourceCheckBox = New-Object System.Windows.Forms.CheckBox
$bulkIntuneSourceCheckBox.Text = 'Intune'
$bulkIntuneSourceCheckBox.Checked = $true
$bulkIntuneSourceCheckBox.AutoSize = $true
$bulkSourceOptionsPanel.Controls.Add($bulkIntuneSourceCheckBox)

$bulkAutopilotSourceCheckBox = New-Object System.Windows.Forms.CheckBox
$bulkAutopilotSourceCheckBox.Text = 'Autopilot'
$bulkAutopilotSourceCheckBox.Checked = $true
$bulkAutopilotSourceCheckBox.AutoSize = $true
$bulkSourceOptionsPanel.Controls.Add($bulkAutopilotSourceCheckBox)

$bulkEntraSourceCheckBox = New-Object System.Windows.Forms.CheckBox
$bulkEntraSourceCheckBox.Text = 'Entra ID'
$bulkEntraSourceCheckBox.Checked = $true
$bulkEntraSourceCheckBox.AutoSize = $true
$bulkSourceOptionsPanel.Controls.Add($bulkEntraSourceCheckBox)

$bulkLinkedCleanupCheckBox = New-Object System.Windows.Forms.CheckBox
$bulkLinkedCleanupCheckBox.Checked = $false
$bulkLinkedCleanupCheckBox.Text = 'Expand selected rows to linked records'
$bulkLinkedCleanupCheckBox.Dock = 'Fill'
$bulkLinkedCleanupCheckBox.Margin = New-Object System.Windows.Forms.Padding(0)
$bulkRightLayout.SetColumnSpan($bulkLinkedCleanupCheckBox, 2)
$bulkRightLayout.Controls.Add($bulkLinkedCleanupCheckBox, 0, 5)

# Row 1: results label
$bulkResultsLabel = New-Object System.Windows.Forms.Label
$bulkResultsLabel.Text = 'Results: search to populate'
$bulkResultsLabel.Dock = 'Fill'
$bulkResultsLabel.TextAlign = 'MiddleLeft'
$bulkResultsLabel.Margin = New-Object System.Windows.Forms.Padding(0)
$tab2Layout.Controls.Add($bulkResultsLabel, 0, 1)

# Row 2: bulk results grid (60% of variable height)
$bulkGrid = New-Object System.Windows.Forms.DataGridView
$bulkGrid.Dock = 'Fill'
$bulkGrid.BackgroundColor = [System.Drawing.Color]::White
$bulkGrid.BorderStyle = 'FixedSingle'
$bulkGrid.SelectionMode = 'FullRowSelect'
$bulkGrid.MultiSelect = $true
$bulkGrid.ReadOnly = $true
$bulkGrid.AllowUserToAddRows = $false
$bulkGrid.AllowUserToDeleteRows = $false
$bulkGrid.AutoSizeRowsMode = 'DisplayedCells'
$bulkGrid.AutoGenerateColumns = $true
$bulkGrid.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
$tab2Layout.Controls.Add($bulkGrid, 0, 2)

# Row 3: bulk log label
$bulkLogLabel = New-Object System.Windows.Forms.Label
$bulkLogLabel.Text = 'Activity log'
$bulkLogLabel.Dock = 'Fill'
$bulkLogLabel.TextAlign = 'MiddleLeft'
$bulkLogLabel.Margin = New-Object System.Windows.Forms.Padding(0)
$tab2Layout.Controls.Add($bulkLogLabel, 0, 3)

# Row 4: bulk log textbox (40% of variable height)
$bulkLogTextBox = New-Object System.Windows.Forms.TextBox
$bulkLogTextBox.Dock = 'Fill'
$bulkLogTextBox.Multiline = $true
$bulkLogTextBox.ScrollBars = 'Vertical'
$bulkLogTextBox.ReadOnly = $true
$bulkLogTextBox.Font = New-Object System.Drawing.Font('Consolas', 10)
$bulkLogTextBox.Margin = New-Object System.Windows.Forms.Padding(0)
$tab2Layout.Controls.Add($bulkLogTextBox, 0, 4)

$script:PrimaryLogTextBox = $logTextBox
$script:SecondaryLogTextBox = $bulkLogTextBox

$connectButton.Add_Click({
    try {
        $form.UseWaitCursor = $true
        $connectButton.Enabled = $false
        $statusLabel.Text = 'Status: Connecting to Microsoft Graph...'
        Write-UiLog -TextBox $logTextBox -Message 'Connecting with popup sign-in (simple mode).'
        $context = Connect-DeviceCleanupGraph -UseDeviceCode:$false -LogTextBox $logTextBox
        $statusLabel.Text = "Status: Connected as $($context.Account) | Tenant $($context.TenantId)"
        $searchButton.Enabled = $true
        $bulkSearchButton.Enabled = $true
        Write-UiLog -TextBox $logTextBox -Message "Connected to Microsoft Graph as $($context.Account) in tenant $($context.TenantId)."
        Write-UiLog -TextBox $logTextBox -Message "Granted scopes: $($context.Scopes -join ', ')"
    }
    catch {
        $statusLabel.Text = 'Status: Connection failed'
        Write-UiErrorDetail -TextBox $logTextBox -Prefix 'Connection failed:' -ErrorRecord $_
        [System.Windows.Forms.MessageBox]::Show("Connection failed.`r`n`r`n$($_.Exception.Message)`r`n`r`nTip: keep this app window in front and allow the Microsoft sign-in popup.", 'Connection Failed', 'OK', 'Error') | Out-Null
    }
    finally {
        $form.UseWaitCursor = $false
        $connectButton.Enabled = $true
    }
})

$searchButton.Add_Click({
    try {
        $term = $searchTextBox.Text.Trim()
        if (-not $term) {
            [System.Windows.Forms.MessageBox]::Show('Enter a device name or serial number first.', 'Missing Search Term', 'OK', 'Warning') | Out-Null
            return
        }

        $sources = New-Object System.Collections.Generic.List[string]
        if ($intuneSourceCheckBox.Checked) { [void]$sources.Add('Intune') }
        if ($autopilotSourceCheckBox.Checked) { [void]$sources.Add('Autopilot') }
        if ($entraSourceCheckBox.Checked) { [void]$sources.Add('Entra') }
        if (-not $sources.Count) {
            [System.Windows.Forms.MessageBox]::Show('Select at least one source: Intune, Autopilot, or Entra ID.', 'No Source Selected', 'OK', 'Warning') | Out-Null
            return
        }

        $form.UseWaitCursor = $true
        $statusLabel.Text = "Status: Searching for $term"
        Search-DeviceEverywhere -SearchTerm $term -LogTextBox $logTextBox -Sources $sources.ToArray() | Out-Null
        Sync-GridData -Grid $grid
        Sync-GridData -Grid $previewGrid -Records $null
        $previewLabel.Text = 'Removal Preview: Select one or more results to see exactly what will be deleted'
        $removeButton.Enabled = $script:SearchResults.Count -gt 0
        $removeAllButton.Enabled = $script:SearchResults.Count -gt 0
        $selectAllButton.Enabled = $script:SearchResults.Count -gt 0
        $statusLabel.Text = "Status: Found $($script:SearchResults.Count) matching record(s)"
    }
    catch {
        $statusLabel.Text = 'Status: Search failed'
        Write-UiErrorDetail -TextBox $logTextBox -Prefix 'Search failed:' -ErrorRecord $_
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Search Failed', 'OK', 'Error') | Out-Null
    }
    finally {
        $form.UseWaitCursor = $false
    }
})

$removeButton.Add_Click({
    try {
        Set-StrictMode -Off

        $selectedRaw = Get-SelectedRecord -Grid $grid
        $selected = New-Object System.Collections.Generic.List[object]
        if ($null -ne $selectedRaw) {
            if ($selectedRaw -is [string] -or $selectedRaw -isnot [System.Collections.IEnumerable]) {
                [void]$selected.Add($selectedRaw)
            }
            else {
                foreach ($selectedItem in $selectedRaw) {
                    [void]$selected.Add($selectedItem)
                }
            }
        }

        if (-not $selected.Count) {
            [System.Windows.Forms.MessageBox]::Show('Select one or more rows to remove.', 'Nothing Selected', 'OK', 'Warning') | Out-Null
            return
        }

        $resolvedRaw = Resolve-RemovalPlan -SeedRecords $selected.ToArray() -AllRecords $script:SearchResults -ExpandLinked:$linkedCleanupCheckBox.Checked
        $selected.Clear()
        if ($null -ne $resolvedRaw) {
            if ($resolvedRaw -is [string] -or $resolvedRaw -isnot [System.Collections.IEnumerable]) {
                [void]$selected.Add($resolvedRaw)
            }
            else {
                foreach ($selectedItem in $resolvedRaw) {
                    [void]$selected.Add($selectedItem)
                }
            }
        }

        Sync-PreviewData -SourceGrid $grid -PreviewGrid $previewGrid -PreviewLabel $previewLabel -ExpandLinked $linkedCleanupCheckBox.Checked
        Write-UiLog -TextBox $logTextBox -Message "Prepared deletion plan for $($selected.Count) record(s)."

        $summary = ($selected | ForEach-Object { "$($_.Source): $($_.DisplayName) [$($_.MatchType)] -> $($_.ExpectedAction)" }) -join [Environment]::NewLine
        $entraWarning = if (@($selected | Where-Object { $_.Source -eq 'Entra ID Device' }).Count -gt 0) {
            "`r`n`r`nWARNING: This plan deletes one or more Entra device identities. For Autopilot deregistration, Microsoft recommends that Entra identities are not deleted by default."
        }
        else { '' }
        $confirmation = [System.Windows.Forms.MessageBox]::Show(
            "Safe cleanup order: Intune -> Autopilot -> Entra ID.`r`n`r`nThis will process $($selected.Count) record(s):`r`n`r`n$summary$entraWarning`r`n`r`nContinue?",
            'Confirm Removal',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        if ($confirmation -ne [System.Windows.Forms.DialogResult]::Yes) {
            return
        }

        $form.UseWaitCursor = $true
        $result = Invoke-RemovalPlan -Records $selected.ToArray() -LogTextBox $logTextBox

        Sync-GridData -Grid $grid
        Sync-PreviewData -SourceGrid $grid -PreviewGrid $previewGrid -PreviewLabel $previewLabel -ExpandLinked $linkedCleanupCheckBox.Checked
        $removeButton.Enabled = $script:SearchResults.Count -gt 0
        $removeAllButton.Enabled = $script:SearchResults.Count -gt 0
        $selectAllButton.Enabled = $script:SearchResults.Count -gt 0
        $statusLabel.Text = "Status: Deleted $($result.DeletedCount), pending $($result.PendingCount), failed $($result.FailedCount)"
        [System.Windows.Forms.MessageBox]::Show("Removal completed.`r`n`r`nDeleted: $($result.DeletedCount)`r`nPending verification: $($result.PendingCount)`r`nFailed: $($result.FailedCount)`r`nSkipped: $($result.SkippedCount)", 'Removal Completed', 'OK', 'Information') | Out-Null
        $searchTextBox.Clear()
    }
    catch {
        $statusLabel.Text = 'Status: Removal failed'
        Write-UiErrorDetail -TextBox $logTextBox -Prefix 'Removal failed:' -ErrorRecord $_
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Removal Failed', 'OK', 'Error') | Out-Null
    }
    finally {
        $form.UseWaitCursor = $false
    }
})

$removeAllButton.Add_Click({
    try {
        Set-StrictMode -Off

        $seedRecords = New-Object System.Collections.Generic.List[object]
        foreach ($record in $script:SearchResults) {
            [void]$seedRecords.Add($record)
        }

        $allRecordsRaw = Resolve-RemovalPlan -SeedRecords $seedRecords.ToArray() -AllRecords $script:SearchResults -ExpandLinked:$false -IncludePartial:$false
        $allRecords = New-Object System.Collections.Generic.List[object]
        if ($null -ne $allRecordsRaw) {
            if ($allRecordsRaw -is [string] -or $allRecordsRaw -isnot [System.Collections.IEnumerable]) {
                [void]$allRecords.Add($allRecordsRaw)
            }
            else {
                foreach ($allRecord in $allRecordsRaw) {
                    [void]$allRecords.Add($allRecord)
                }
            }
        }

        if (-not $allRecords.Count) {
            [System.Windows.Forms.MessageBox]::Show('There are no exact search results to remove. Partial matches require explicit row selection.', 'No Exact Matches', 'OK', 'Information') | Out-Null
            return
        }

        Sync-GridData -Grid $previewGrid -Records $allRecords
        $previewLabel.Text = "Removal Preview: $($allRecords.Count) found record(s) will be deleted"
        Write-UiLog -TextBox $logTextBox -Message "Prepared deletion plan for all $($allRecords.Count) found record(s)."

        $entraWarning = if (@($allRecords | Where-Object { $_.Source -eq 'Entra ID Device' }).Count -gt 0) {
            "`r`n`r`nWARNING: This plan deletes one or more Entra device identities."
        }
        else { '' }
        $confirmation = [System.Windows.Forms.MessageBox]::Show(
            "Safe cleanup order: Intune -> Autopilot -> Entra ID.`r`n`r`nThis will process all $($allRecords.Count) exact/linked record(s). Partial matches are excluded.$entraWarning`r`n`r`nContinue?",
            'Confirm Remove All',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        if ($confirmation -ne [System.Windows.Forms.DialogResult]::Yes) {
            return
        }

        $form.UseWaitCursor = $true
        $result = Invoke-RemovalPlan -Records $allRecords.ToArray() -LogTextBox $logTextBox
        Sync-GridData -Grid $grid
        Sync-GridData -Grid $previewGrid -Records $null
        $previewLabel.Text = 'Removal Preview: Select one or more results to see exactly what will be deleted'
        $removeButton.Enabled = $script:SearchResults.Count -gt 0
        $removeAllButton.Enabled = $script:SearchResults.Count -gt 0
        $selectAllButton.Enabled = $script:SearchResults.Count -gt 0
        $statusLabel.Text = "Status: Deleted $($result.DeletedCount), pending $($result.PendingCount), failed $($result.FailedCount)"
        [System.Windows.Forms.MessageBox]::Show("Removal completed.`r`n`r`nDeleted: $($result.DeletedCount)`r`nPending verification: $($result.PendingCount)`r`nFailed: $($result.FailedCount)", 'Removal Completed', 'OK', 'Information') | Out-Null
        $searchTextBox.Clear()
    }
    catch {
        $statusLabel.Text = 'Status: Remove all failed'
        Write-UiErrorDetail -TextBox $logTextBox -Prefix 'Remove all failed:' -ErrorRecord $_
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Remove All Failed', 'OK', 'Error') | Out-Null
    }
    finally {
        $form.UseWaitCursor = $false
    }
})

$selectAllButton.Add_Click({
    $grid.SelectAll()
})

$clearButton.Add_Click({
    $searchTextBox.Clear()
    Clear-UiLog
    $script:SearchResults.Clear()
    $script:PreviewResults.Clear()
    $script:CurrentSearchTerm = ''
    Sync-GridData -Grid $grid
    Sync-GridData -Grid $previewGrid -Records $null
    $removeButton.Enabled = $false
    $removeAllButton.Enabled = $false
    $selectAllButton.Enabled = $false
    $previewLabel.Text = 'Removal Preview: Select one or more results to see exactly what will be deleted'
    $statusLabel.Text = 'Status: Cleared current results'
})

$grid.Add_SelectionChanged({
    Sync-PreviewData -SourceGrid $grid -PreviewGrid $previewGrid -PreviewLabel $previewLabel -ExpandLinked $linkedCleanupCheckBox.Checked
})

$linkedCleanupCheckBox.Add_CheckedChanged({
    Sync-PreviewData -SourceGrid $grid -PreviewGrid $previewGrid -PreviewLabel $previewLabel -ExpandLinked $linkedCleanupCheckBox.Checked
})

$searchTextBox.Add_KeyDown({
    param($sender, $keyEventArgs)

    if ($sender.Enabled -and $keyEventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Enter -and $searchButton.Enabled) {
        $searchButton.PerformClick()
        $keyEventArgs.SuppressKeyPress = $true
    }
})

# Bulk tab event handlers

$bulkLoadFileButton.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Title = 'Open CSV or TXT file with device names/serials'
    $ofd.Filter = 'CSV files (*.csv)|*.csv|Text files (*.txt)|*.txt|All files (*.*)|*.*'
    $ofd.FilterIndex = 1

    if ($ofd.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }

    try {
        $ext = [System.IO.Path]::GetExtension($ofd.FileName).ToLower()
        $terms = New-Object System.Collections.Generic.List[string]

        if ($ext -eq '.csv') {
            $columnName = $bulkCsvColumnTextBox.Text.Trim()
            if (-not $columnName) {
                [System.Windows.Forms.MessageBox]::Show('Enter a CSV column name first.', 'Column Required', 'OK', 'Warning') | Out-Null
                return
            }

            $rows = Import-Csv -Path $ofd.FileName
            foreach ($row in $rows) {
                $val = $row.PSObject.Properties[$columnName]
                if ($val -and $val.Value -and ([string]$val.Value).Trim()) {
                    [void]$terms.Add(([string]$val.Value).Trim())
                }
            }

            if (-not $terms.Count) {
                [System.Windows.Forms.MessageBox]::Show("No values found in column '$columnName'. Check the column name matches exactly (case-sensitive).", 'No Data', 'OK', 'Warning') | Out-Null
                return
            }
        }
        else {
            $lines = Get-Content -Path $ofd.FileName
            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if ($trimmed) {
                    [void]$terms.Add($trimmed)
                }
            }
        }

        $bulkInputTextBox.Lines = $terms.ToArray()
        Write-UiLog -TextBox $bulkLogTextBox -Message "Loaded $($terms.Count) term(s) from $([System.IO.Path]::GetFileName($ofd.FileName))."
    }
    catch {
        Write-UiErrorDetail -TextBox $bulkLogTextBox -Prefix 'File load failed:' -ErrorRecord $_
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'File Load Failed', 'OK', 'Error') | Out-Null
    }
})

$bulkSearchButton.Add_Click({
    param($sender, $eventArgs)

    try {
        Set-StrictMode -Off

        if ([string]::IsNullOrWhiteSpace($bulkInputTextBox.Text)) {
            [System.Windows.Forms.MessageBox]::Show('Enter at least one device name or serial number.', 'Nothing to Search', 'OK', 'Warning') | Out-Null
            return
        }

        [string[]]$lineValues = $bulkInputTextBox.Lines
        if (-not $lineValues.Length) {
            [System.Windows.Forms.MessageBox]::Show('Enter at least one device name or serial number.', 'Nothing to Search', 'OK', 'Warning') | Out-Null
            return
        }

        $termSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($lineValue in $lineValues) {
            if ($null -eq $lineValue) {
                continue
            }

            $termValue = ([string]$lineValue).Trim()
            if ([string]::IsNullOrWhiteSpace($termValue)) {
                continue
            }

            [void]$termSet.Add($termValue)
        }

        $terms = New-Object System.Collections.Generic.List[string]
        foreach ($sortedTerm in ($termSet | Sort-Object)) {
            [void]$terms.Add([string]$sortedTerm)
        }

        if (-not $terms.Count) {
            [System.Windows.Forms.MessageBox]::Show('No unique search terms found.', 'Nothing to Search', 'OK', 'Warning') | Out-Null
            return
        }

        $bulkSources = New-Object System.Collections.Generic.List[string]
        if ($bulkIntuneSourceCheckBox.Checked) { [void]$bulkSources.Add('Intune') }
        if ($bulkAutopilotSourceCheckBox.Checked) { [void]$bulkSources.Add('Autopilot') }
        if ($bulkEntraSourceCheckBox.Checked) { [void]$bulkSources.Add('Entra') }
        if (-not $bulkSources.Count) {
            [System.Windows.Forms.MessageBox]::Show('Select at least one source: Intune, Autopilot, or Entra ID.', 'No Source Selected', 'OK', 'Warning') | Out-Null
            return
        }

        $form.UseWaitCursor = $true
        $bulkSearchButton.Enabled = $false
        $bulkRemoveAllButton.Enabled = $false
        $bulkRemoveSelectedButton.Enabled = $false
        $bulkExportPlanButton.Enabled = $false
        $script:BulkAllResults.Clear()
        $script:BulkInputTerms.Clear()
        foreach ($t in $terms) {
            [void]$script:BulkInputTerms.Add($t)
        }

        Write-UiLog -TextBox $bulkLogTextBox -Message "Starting bulk search for $($terms.Count) term(s)..."
        $statusLabel.Text = "Status: Bulk searching $($terms.Count) term(s)..."

        for ($i = 0; $i -lt $terms.Count; $i++) {
            $term = $terms[$i]
            Write-UiLog -TextBox $bulkLogTextBox -Message "[$($i+1)/$($terms.Count)] Searching '$term'..."
            $script:CurrentSearchTerm = $term
            $script:SearchResults.Clear()
            Search-DeviceEverywhere -SearchTerm $term -LogTextBox $bulkLogTextBox -Sources $bulkSources.ToArray() | Out-Null

            foreach ($r in $script:SearchResults) {
                [void]$script:BulkAllResults.Add($r)
            }
        }

        # Deduplicate combined results
        $uniqueBulk = Get-UniqueResultsByRecordId -Items $script:BulkAllResults
        $script:BulkAllResults.Clear()
        foreach ($r in $uniqueBulk) {
            [void]$script:BulkAllResults.Add($r)
        }

        Sync-GridData -Grid $bulkGrid -Records $script:BulkAllResults
        $bulkResultsLabel.Text = "Results: Found $($script:BulkAllResults.Count) unique record(s) across $($terms.Count) search term(s)"
        $exactBulkCount = @($script:BulkAllResults | Where-Object { $_.MatchType -ne 'Partial' }).Count
        $bulkRemoveAllButton.Enabled = $exactBulkCount -gt 0
        $bulkRemoveSelectedButton.Enabled = $script:BulkAllResults.Count -gt 0
        $bulkExportPlanButton.Enabled = $script:BulkAllResults.Count -gt 0
        $statusLabel.Text = "Status: Bulk search done - $($script:BulkAllResults.Count) record(s) found"
        Write-UiLog -TextBox $bulkLogTextBox -Message "Bulk search complete. $($script:BulkAllResults.Count) unique record(s) found."
    }
    catch {
        Write-UiErrorDetail -TextBox $bulkLogTextBox -Prefix 'Bulk search failed:' -ErrorRecord $_
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Bulk Search Failed', 'OK', 'Error') | Out-Null
        $statusLabel.Text = 'Status: Bulk search failed'
    }
    finally {
        $form.UseWaitCursor = $false
        $bulkSearchButton.Enabled = $true
    }
})

$invokeBulkRemoval = {
    param([bool]$SelectedOnly)

    Set-StrictMode -Off

    if (-not $script:BulkAllResults.Count) {
        [System.Windows.Forms.MessageBox]::Show('No results to remove. Run Search All first.', 'Nothing Found', 'OK', 'Information') | Out-Null
        return
    }

    $seedRecords = New-Object System.Collections.Generic.List[object]
    if ($SelectedOnly) {
        foreach ($bulkRecord in (Get-SelectedRecord -Grid $bulkGrid)) {
            [void]$seedRecords.Add($bulkRecord)
        }
        if (-not $seedRecords.Count) {
            [System.Windows.Forms.MessageBox]::Show('Select one or more bulk result rows first.', 'Nothing Selected', 'OK', 'Warning') | Out-Null
            return
        }
    }
    else {
        foreach ($bulkRecord in ($script:BulkAllResults | Where-Object { $_.MatchType -ne 'Partial' })) {
            [void]$seedRecords.Add($bulkRecord)
        }
    }

    $toDeleteRaw = Resolve-RemovalPlan -SeedRecords $seedRecords.ToArray() -AllRecords $script:BulkAllResults -ExpandLinked:$bulkLinkedCleanupCheckBox.Checked -IncludePartial:$SelectedOnly
    $toDelete = New-Object System.Collections.Generic.List[object]
    if ($null -ne $toDeleteRaw) {
        if ($toDeleteRaw -is [string] -or $toDeleteRaw -isnot [System.Collections.IEnumerable]) {
            [void]$toDelete.Add($toDeleteRaw)
        }
        else {
            foreach ($deleteItem in $toDeleteRaw) {
                [void]$toDelete.Add($deleteItem)
            }
        }
    }

    if (-not $toDelete.Count) {
        [System.Windows.Forms.MessageBox]::Show('No removable records found for the current bulk selection.', 'Nothing To Remove', 'OK', 'Information') | Out-Null
        return
    }
    $summary = ($toDelete | Select-Object -First 20 | ForEach-Object { "$($_.Source): $($_.DisplayName) [$($_.MatchType)] -> $($_.ExpectedAction)" }) -join [Environment]::NewLine
    if ($toDelete.Count -gt 20) {
        $summary += [Environment]::NewLine + "... and $($toDelete.Count - 20) more"
    }

    $entraWarning = if (@($toDelete | Where-Object { $_.Source -eq 'Entra ID Device' }).Count -gt 0) {
        "`r`n`r`nWARNING: This plan deletes one or more Entra device identities."
    }
    else { '' }

    $confirmation = [System.Windows.Forms.MessageBox]::Show(
        "Safe cleanup order: Intune -> Autopilot -> Entra ID.`r`n`r`nThis will process $($toDelete.Count) record(s):`r`n`r`n$summary$entraWarning`r`n`r`nContinue?",
        'Confirm Bulk Removal',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($confirmation -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    try {
        $form.UseWaitCursor = $true
        $bulkRemoveAllButton.Enabled = $false
        $bulkRemoveSelectedButton.Enabled = $false
        $statusLabel.Text = "Status: Bulk removing $($toDelete.Count) record(s)..."
        $result = Invoke-RemovalPlan -Records $toDelete.ToArray() -LogTextBox $bulkLogTextBox

        $successfulKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($successfulKey in $result.SuccessfulRecordKeys) {
            [void]$successfulKeys.Add([string]$successfulKey)
        }

        # Keep failed and pending records visible so the operator can review or retry them.
        $remaining = $script:BulkAllResults | Where-Object {
            -not $successfulKeys.Contains("$($_.Source)|$($_.RecordId)")
        }
        $script:BulkAllResults.Clear()
        foreach ($r in $remaining) {
            [void]$script:BulkAllResults.Add($r)
        }

        Sync-GridData -Grid $bulkGrid -Records $script:BulkAllResults
        $bulkResultsLabel.Text = "Results: $($script:BulkAllResults.Count) record(s) remaining"
        $exactRemainingCount = @($script:BulkAllResults | Where-Object { $_.MatchType -ne 'Partial' }).Count
        $bulkRemoveAllButton.Enabled = $exactRemainingCount -gt 0
        $bulkRemoveSelectedButton.Enabled = $script:BulkAllResults.Count -gt 0
        $bulkExportPlanButton.Enabled = $script:BulkAllResults.Count -gt 0
        $statusLabel.Text = "Status: Bulk done - deleted $($result.DeletedCount), pending $($result.PendingCount), failed $($result.FailedCount)"
        Write-UiLog -TextBox $bulkLogTextBox -Message "Bulk removal complete. Deleted: $($result.DeletedCount), pending: $($result.PendingCount), failed: $($result.FailedCount)."
        [System.Windows.Forms.MessageBox]::Show("Bulk removal completed.`r`n`r`nDeleted: $($result.DeletedCount)`r`nPending verification: $($result.PendingCount)`r`nFailed: $($result.FailedCount)`r`nSkipped: $($result.SkippedCount)", 'Bulk Removal Completed', 'OK', 'Information') | Out-Null
        if (-not $script:BulkAllResults.Count) {
            $bulkInputTextBox.Clear()
        }
    }
    catch {
        Write-UiErrorDetail -TextBox $bulkLogTextBox -Prefix 'Bulk removal failed:' -ErrorRecord $_
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Bulk Removal Failed', 'OK', 'Error') | Out-Null
        $statusLabel.Text = 'Status: Bulk removal failed'
    }
    finally {
        $form.UseWaitCursor = $false
        if ($script:BulkAllResults.Count -gt 0) {
            $bulkRemoveSelectedButton.Enabled = $true
            $bulkExportPlanButton.Enabled = $true
            $bulkRemoveAllButton.Enabled = @($script:BulkAllResults | Where-Object { $_.MatchType -ne 'Partial' }).Count -gt 0
        }
    }
}

$bulkRemoveAllButton.Add_Click({
    & $invokeBulkRemoval -SelectedOnly $false
})

$bulkRemoveSelectedButton.Add_Click({
    & $invokeBulkRemoval -SelectedOnly $true
})

$bulkExportPlanButton.Add_Click({
    if (-not $script:BulkAllResults.Count) {
        [System.Windows.Forms.MessageBox]::Show('Run a bulk search before exporting a dry-run plan.', 'Nothing To Export', 'OK', 'Information') | Out-Null
        return
    }

    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Title = 'Export dry-run removal plan'
    $sfd.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
    $sfd.FileName = "remove-device-dry-run-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
    if ($sfd.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }

    try {
        $planOrder = 0
        $exportRows = foreach ($record in (Sort-RemovalPlan -Records $script:BulkAllResults)) {
            $planOrder++
            [PSCustomObject]@{
                PlanOrder       = $planOrder
                AutomaticallyEligible = ($record.MatchType -ne 'Partial')
                InputTerm       = $record.InputTerm
                MatchType       = $record.MatchType
                Source          = $record.Source
                DisplayName     = $record.DisplayName
                SerialNumber    = $record.SerialNumber
                OperatingSystem = $record.OperatingSystem
                LastActivity    = $record.LastActivity
                EnrollmentType  = $record.EnrollmentType
                Ownership       = $record.Ownership
                ExpectedAction  = $record.ExpectedAction
                RecordId        = $record.RecordId
                AzureDeviceId   = $record.AzureDeviceId
            }
        }

        $exportRows | Export-Csv -Path $sfd.FileName -NoTypeInformation -Encoding UTF8
        Write-UiLog -TextBox $bulkLogTextBox -Message "Dry-run plan exported to $($sfd.FileName)."
        [System.Windows.Forms.MessageBox]::Show("Dry-run plan exported to:`r`n$($sfd.FileName)", 'Export Complete', 'OK', 'Information') | Out-Null
    }
    catch {
        Write-UiErrorDetail -TextBox $bulkLogTextBox -Prefix 'Dry-run export failed:' -ErrorRecord $_
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Export Failed', 'OK', 'Error') | Out-Null
    }
})

$bulkClearButton.Add_Click({
    $bulkInputTextBox.Clear()
    Clear-UiLog
    $script:BulkAllResults.Clear()
    $script:BulkInputTerms.Clear()
    Sync-GridData -Grid $bulkGrid -Records $null
    $bulkResultsLabel.Text = 'Results: search to populate'
    $bulkRemoveAllButton.Enabled = $false
    $bulkRemoveSelectedButton.Enabled = $false
    $bulkExportPlanButton.Enabled = $false
    $statusLabel.Text = 'Status: Bulk results cleared'
})

# Menu handlers
$projectGitHubUrl = 'https://github.com/enginsoysal/remove-device-everywhere'

$fileLoadBulkInputMenuItem.Add_Click({
    $tabControl.SelectedTab = $tab2
    $bulkLoadFileButton.PerformClick()
})

$fileExportCurrentLogMenuItem.Add_Click({
    $activeLogTextBox = if ($tabControl.SelectedTab -eq $tab2) { $bulkLogTextBox } else { $logTextBox }
    if (-not $activeLogTextBox.Text.Trim()) {
        [System.Windows.Forms.MessageBox]::Show('There is no log content to export.', 'Nothing to Export', 'OK', 'Information') | Out-Null
        return
    }

    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Title = 'Export activity log'
    $sfd.Filter = 'Text files (*.txt)|*.txt|Log files (*.log)|*.log|All files (*.*)|*.*'
    $sfd.FileName = "remove-device-log-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"

    if ($sfd.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }

    try {
        [System.IO.File]::WriteAllText($sfd.FileName, $activeLogTextBox.Text)
        [System.Windows.Forms.MessageBox]::Show("Log exported to:`r`n$($sfd.FileName)", 'Export Complete', 'OK', 'Information') | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Export Failed', 'OK', 'Error') | Out-Null
    }
})

$fileOpenAuditFolderMenuItem.Add_Click({
    try {
        Initialize-AuditLog
        Start-Process -FilePath 'explorer.exe' -ArgumentList $script:AuditDirectory | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Open Folder Failed', 'OK', 'Error') | Out-Null
    }
})

$fileOpenAuditCsvMenuItem.Add_Click({
    try {
        Initialize-AuditLog
        if (-not (Test-Path -Path $script:AuditLogPath)) {
            [System.Windows.Forms.MessageBox]::Show('Current audit file does not exist yet. Delete something first to create it.', 'Audit File Not Found', 'OK', 'Information') | Out-Null
            return
        }

        Start-Process -FilePath $script:AuditLogPath | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Open CSV Failed', 'OK', 'Error') | Out-Null
    }
})

$fileExitMenuItem.Add_Click({
    $form.Close()
})

$toolsConnectMenuItem.Add_Click({
    $connectButton.PerformClick()
})

$toolsClearSingleMenuItem.Add_Click({
    $tabControl.SelectedTab = $tab1
    $clearButton.PerformClick()
})

$toolsClearBulkMenuItem.Add_Click({
    $tabControl.SelectedTab = $tab2
    $bulkClearButton.PerformClick()
})

$helpGithubMenuItem.Add_Click({
    Start-Process -FilePath $projectGitHubUrl | Out-Null
})

$helpAboutMenuItem.Add_Click({
    $aboutText = @"
Remove Device Everywhere
Version: $script:AppVersion

Searches and removes device records across:
- Intune Managed Devices
- Entra ID Devices
- Windows Autopilot

Safe Cleanup release for controlled operational device removal.
"@

    [System.Windows.Forms.MessageBox]::Show(
        $aboutText,
        'About Remove Device Everywhere',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
})

Sync-GridData -Grid $grid
Sync-GridData -Grid $previewGrid -Records $null
Write-UiLog -TextBox $logTextBox -Message 'Ready. Connect to Microsoft Graph, search by exact device name or serial number, then remove the records you select.'
Write-UiLog -TextBox $logTextBox -Message 'Safe Cleanup v1.1 orders removals as Intune -> Autopilot -> Entra ID. Partial matches require explicit selection.'
Write-UiLog -TextBox $logTextBox -Message 'Linked cleanup is off by default. Review Expected action because Intune delete can retire or wipe a managed device depending on enrollment type.'
Write-UiLog -TextBox $logTextBox -Message 'This is a GUI app: terminal can remain empty while this window is open.'
Write-UiLog -TextBox $logTextBox -Message 'Simple mode is active: Connect Graph uses popup sign-in (no terminal steps).'
Write-UiLog -TextBox $logTextBox -Message 'Module bootstrap is non-interactive. If Microsoft.Graph.Authentication is missing, the script will install NuGet and the module automatically for the current user.'
Write-UiLog -TextBox $logTextBox -Message "Audit log file: $script:AuditLogPath"
Write-UiLog -TextBox $logTextBox -Message "Preferred Graph auth version for this host: $(if ($script:PreferredGraphAuthVersion) { $script:PreferredGraphAuthVersion } else { 'latest available' })"

if ($SmokeTest) {
    $form.Add_Shown({
        $form.BeginInvoke([Action]{ $form.Close() }) | Out-Null
    })
}

[void]$form.ShowDialog()
#pragma warning restore PSUseApprovedVerbs
