Describe 'Remove-DeviceEverywhere script quality checks' {
    BeforeAll {
        $scriptPath = Join-Path $PSScriptRoot '..\Remove-DeviceEverywhere.ps1'
        $scriptPath = [System.IO.Path]::GetFullPath($scriptPath)
    }

    It 'parses without syntax errors' {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count | Should Be 0
    }

    It 'contains PSScriptInfo metadata block' {
        $content = Get-Content -Path $scriptPath -Raw
        $content | Should Match '<#PSScriptInfo'
        $content | Should Match '\.VERSION\s+1\.0\.0'
        $content | Should Match '\.PROJECTURI\s+https://github.com/enginsoysal/remove-device-everywhere'
    }
}
