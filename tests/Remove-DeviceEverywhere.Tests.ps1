BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..\Remove-DeviceEverywhere.ps1'
    $scriptPath = [System.IO.Path]::GetFullPath($scriptPath)
    . $scriptPath -NoGui

    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        function Invoke-MgGraphRequest {
            param($Method, $Uri, $OutputType, $Body, $ContentType)
            throw 'Invoke-MgGraphRequest test stub was not mocked.'
        }
    }

    function New-TestRecord {
        param(
            [string]$Source,
            [string]$RecordId,
            [string]$MatchType = 'Exact',
            [string]$InputTerm = 'DEVICE-01'
        )

        ConvertTo-ResultObject `
            -Source $Source `
            -DisplayName "Device-$RecordId" `
            -RecordId $RecordId `
            -MatchType $MatchType `
            -InputTerm $InputTerm `
            -DeleteUri "https://graph.microsoft.com/v1.0/test/$RecordId"
    }
}

Describe 'Remove-DeviceEverywhere release metadata' {
    It 'parses without syntax errors' {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count | Should -Be 0
    }

    It 'contains the 1.1.0 PSScriptInfo metadata' {
        $content = Get-Content -Path $scriptPath -Raw
        $content | Should -Match '<#PSScriptInfo'
        $content | Should -Match '\.VERSION\s+1\.1\.0'
        $content | Should -Match '\$script:AppVersion\s*=\s*''1\.1\.0'''
        $content | Should -Match '\.PROJECTURI\s+https://github.com/enginsoysal/remove-device-everywhere'
    }

    It 'keeps linked cleanup disabled by default' {
        $content = Get-Content -Path $scriptPath -Raw
        $content | Should -Match '\$linkedCleanupCheckBox\.Checked\s*=\s*\$false'
        $content | Should -Match '\$bulkLinkedCleanupCheckBox\.Checked\s*=\s*\$false'
    }

    It 'uses stable Autopilot v1.0 list and delete endpoints' {
        $content = Get-Content -Path $scriptPath -Raw
        $content | Should -Match 'graph\.microsoft\.com/v1\.0/deviceManagement/windowsAutopilotDeviceIdentities'
        $content | Should -Not -Match 'graph\.microsoft\.com/beta/deviceManagement/windowsAutopilotDeviceIdentities\?'
    }

    It 'ships an executable with matching 1.1.0 version metadata and checksum' {
        $exePath = Join-Path $PSScriptRoot '..\dist\Remove-DeviceEverywhere.exe'
        $checksumPath = Join-Path $PSScriptRoot '..\dist\SHA256SUMS.txt'
        $exeVersion = (Get-Item $exePath).VersionInfo.FileVersion
        $expectedHash = ((Get-Content $checksumPath -Raw).Trim() -split '\s+')[0]
        $actualHash = (Get-FileHash $exePath -Algorithm SHA256).Hash

        $exeVersion | Should -Be '1.1.0.0'
        $actualHash | Should -Be $expectedHash
    }
}

Describe 'Match safety' {
    It 'returns only exact matches when an exact value exists' {
        $items = @(
            [PSCustomObject]@{ deviceName = 'DEVICE-01'; serialNumber = 'SERIAL-01' }
            [PSCustomObject]@{ deviceName = 'DEVICE-010'; serialNumber = 'SERIAL-010' }
        )

        $result = @(Get-LocalMatchingItem -Items $items -SearchTerm 'DEVICE-01' -PropertyNames @('deviceName', 'serialNumber'))

        $result.Count | Should -Be 1
        $result[0].deviceName | Should -Be 'DEVICE-01'
        $result[0]._RdeMatchType | Should -Be 'Exact'
    }

    It 'marks contains-only fallback results as partial' {
        $items = @(
            [PSCustomObject]@{ deviceName = 'DEVICE-010'; serialNumber = 'SERIAL-010' }
            [PSCustomObject]@{ deviceName = 'DEVICE-011'; serialNumber = 'SERIAL-011' }
        )

        $result = @(Get-LocalMatchingItem -Items $items -SearchTerm 'DEVICE-01' -PropertyNames @('deviceName', 'serialNumber'))

        $result.Count | Should -Be 2
        @($result | Where-Object _RdeMatchType -eq 'Partial').Count | Should -Be 2
    }

    It 'excludes partial matches from automatic removal plans' {
        $records = New-Object System.Collections.Generic.List[object]
        [void]$records.Add((New-TestRecord -Source 'Intune Managed Device' -RecordId '1' -MatchType 'Exact'))
        [void]$records.Add((New-TestRecord -Source 'Entra ID Device' -RecordId '2' -MatchType 'Partial'))

        $plan = @(Resolve-RemovalPlan -SeedRecords $records.ToArray() -AllRecords $records -ExpandLinked:$false -IncludePartial:$false)

        $plan.Count | Should -Be 1
        $plan[0].RecordId | Should -Be '1'
    }
}

Describe 'Safe removal ordering' {
    It 'orders Intune before Autopilot before Entra ID' {
        $records = @(
            (New-TestRecord -Source 'Entra ID Device' -RecordId '3')
            (New-TestRecord -Source 'Windows Autopilot' -RecordId '2')
            (New-TestRecord -Source 'Intune Managed Device' -RecordId '1')
        )

        $ordered = @(Sort-RemovalPlan -Records $records)

        ($ordered.Source -join ',') | Should -Be 'Intune Managed Device,Windows Autopilot,Entra ID Device'
    }
}

Describe 'Graph resilience' {
    BeforeEach {
        $global:RdeGraphCallCount = 0
        Mock Start-Sleep {}
    }

    It 'retries a throttled Graph request' {
        Mock Invoke-MgGraphRequest {
            $global:RdeGraphCallCount++
            if ($global:RdeGraphCallCount -eq 1) {
                throw '429 Too Many Requests. Retry-After: 1'
            }
            return [PSCustomObject]@{ value = @('ok') }
        }

        $result = Invoke-DeviceCleanupGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/test' -OutputType PSObject

        $global:RdeGraphCallCount | Should -Be 2
        $result.value[0] | Should -Be 'ok'
        Should -Invoke Start-Sleep -Times 1
    }
}

Describe 'Per-record removal outcomes' {
    BeforeEach {
        $script:SearchResults.Clear()
        Mock Write-AuditEntry {}
        Mock Write-UiLog {}
        Mock Write-UiErrorDetail {}
        $script:testLogTextBox = New-Object System.Windows.Forms.TextBox
    }

    It 'does not count a skipped record as deleted' {
        $record = New-TestRecord -Source 'Intune Managed Device' -RecordId 'skip-1'
        [void]$script:SearchResults.Add($record)
        Mock Invoke-DeviceRecordRemoval { 'Skipped' }

        $result = Invoke-RemovalPlan -Records @($record) -LogTextBox $script:testLogTextBox

        $result.DeletedCount | Should -Be 0
        $result.SkippedCount | Should -Be 1
        $script:SearchResults.Count | Should -Be 1
        Should -Invoke Write-AuditEntry -Times 1 -ParameterFilter { $Outcome -eq 'Skipped' }
    }

    It 'keeps a pending record available for later verification' {
        $record = New-TestRecord -Source 'Windows Autopilot' -RecordId 'pending-1'
        [void]$script:SearchResults.Add($record)
        Mock Invoke-DeviceRecordRemoval { 'Pending' }

        $result = Invoke-RemovalPlan -Records @($record) -LogTextBox $script:testLogTextBox

        $result.PendingCount | Should -Be 1
        $script:SearchResults.Count | Should -Be 1
        $record.ResultStatus | Should -Be 'Pending'
        Should -Invoke Write-AuditEntry -Times 1 -ParameterFilter { $Outcome -eq 'Pending' }
    }
}

Describe 'Audit v2' {
    It 'writes the record input term and connected tenant context' {
        $script:AuditDirectory = $TestDrive
        $script:AuditLogPath = Join-Path $TestDrive 'audit.csv'
        $script:GraphContext = [PSCustomObject]@{ TenantId = 'tenant-123'; Account = 'admin@example.com' }
        $record = New-TestRecord -Source 'Entra ID Device' -RecordId 'audit-1' -InputTerm 'ORIGINAL-TERM'

        Write-AuditEntry -Record $record -Outcome 'Failed' -Message 'Test failure'
        $row = Import-Csv $script:AuditLogPath

        $row.SearchTerm | Should -Be 'ORIGINAL-TERM'
        $row.TenantId | Should -Be 'tenant-123'
        $row.Operator | Should -Be 'admin@example.com'
        $row.Outcome | Should -Be 'Failed'
        $row.SessionId | Should -Not -BeNullOrEmpty
    }
}
