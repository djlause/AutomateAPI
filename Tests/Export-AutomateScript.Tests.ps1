# Pester 5 tests for Export-AutomateScript. They use the XML fixtures in Tests\Fixtures and need no
# Automate server or database.
#   Needs Pester 5 (Install-Module Pester -Force -SkipPublisherCheck -Scope CurrentUser), then:
#   Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path .\Tests\Export-AutomateScript.Tests.ps1

# Windows PowerShell ships with Pester 3.4, which cannot run these tests. Stop with a clear message.
$LoadedPester = Get-Module Pester
if ($LoadedPester -and $LoadedPester.Version.Major -lt 5) {
    throw ("These tests need Pester 5 or later, but Pester $($LoadedPester.Version) is loaded. Run: " +
        "Install-Module Pester -Force -SkipPublisherCheck -Scope CurrentUser; then open a new PowerShell window and run " +
        "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path .\Tests\Export-AutomateScript.Tests.ps1")
}

BeforeAll {
    Get-Module AutomateAPI | Remove-Module -Force
    Import-Module (Join-Path $PSScriptRoot '..\AutomateAPI.psd1') -Force
    $Fixtures = Join-Path $PSScriptRoot 'Fixtures'
    $Out = Join-Path ([System.IO.Path]::GetTempPath()) ("AutomateScriptExport-" + [guid]::NewGuid())
    $Scripts = Export-AutomateScript -XmlPath $Fixtures -OutputPath $Out -PassThru -WarningAction SilentlyContinue
}

AfterAll {
    if ($Out -and (Test-Path $Out)) { Remove-Item $Out -Recurse -Force }
}

Describe 'Export-AutomateScript from XML exports' {
    It 'reads every script, including scripts packed inside another export' {
        @($Scripts).Count | Should -Be 3
        ($Scripts.ScriptName | Sort-Object) | Should -Be @('Cleanup: Temp/Files', 'Export Test', 'Install Agent Tools')
    }

    It 'builds nested folder paths' {
        ($Scripts | Where-Object ScriptId -eq '501').FolderPath | Should -Be 'Software\Installs'
    }

    It 'decodes steps in IF / THEN / ELSE order with names and readable values' {
        $Steps = ($Scripts | Where-Object ScriptId -eq '6401').Steps
        $Steps.Count | Should -Be 3
        $Steps[0].Section | Should -Be 'InitialCheck'
        $Steps[1].Description | Should -Be 'Variable Set: Set Type=Properties; Parameter=set properties; Variable Name=variableName'
        $Steps[1].OnFailure | Should -Be 'Continue on failure'
        $Steps[2].Description | Should -Be 'Note: This is a script note in the Export Test file.'
    }

    It 'names the script that a Script Run step calls' {
        $Script = $Scripts | Where-Object ScriptId -eq '501'
        $Script.CalledScripts | Should -Contain '[Maintenance\Cleanup: Temp/Files] (script 502)'
    }

    It 'finds script variables and Automate variables' {
        $Script = $Scripts | Where-Object ScriptId -eq '501'
        $Script.VariablesSet | Should -Contain 'InstallDir'
        $Script.VariablesUsed | Should -Contain 'psout'
        $Script.SystemVariables | Should -Contain 'computername'
    }

    It 'marks disabled steps' {
        $Step = ($Scripts | Where-Object ScriptId -eq '501').Steps | Where-Object FunctionName -eq 'Shell'
        $Step.Disabled | Should -BeTrue
    }

    It 'saves embedded PowerShell to its own file' {
        $File = Get-ChildItem -Path $Out -Recurse -Filter 'Then-02.ps1'
        $File | Should -Not -BeNullOrEmpty
        Get-Content $File.FullName -Raw | Should -Match 'Test-Path \$path'
    }

    It 'warns about step functions it does not know' {
        ($Scripts | Where-Object ScriptId -eq '502').Warnings | Should -Contain 'THEN step 3 uses function 999, which is not in the catalog.'
    }

    It 'writes the summary files' {
        foreach ($Name in 'index.csv', 'function-usage.csv', 'folders.csv', 'README.md') {
            Join-Path $Out $Name | Should -Exist
        }
        @(Import-Csv (Join-Path $Out 'index.csv')).Count | Should -Be 3
    }

    It 'writes a page and a JSON file per script with safe file names' {
        Join-Path $Out 'Scripts\Maintenance\502 - Cleanup_ Temp_Files.md' | Should -Exist
        Join-Path $Out 'Scripts\Maintenance\502 - Cleanup_ Temp_Files.json' | Should -Exist
    }
}

Describe 'ConvertFrom-AutomateScriptBlob' {
    It 'accepts raw gzip bytes as stored in lt_scripts' {
        InModuleScope AutomateAPI {
            $Text = '<ScriptData><ScriptSteps /></ScriptData>'
            $Memory = New-Object System.IO.MemoryStream
            $Gzip = New-Object System.IO.Compression.GZipStream($Memory, [System.IO.Compression.CompressionMode]::Compress)
            $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
            $Gzip.Write($Bytes, 0, $Bytes.Length); $Gzip.Dispose()
            ConvertFrom-AutomateScriptBlob -Value $Memory.ToArray() | Should -Be $Text
        }
    }

    It 'returns nothing for an empty value' {
        InModuleScope AutomateAPI {
            ConvertFrom-AutomateScriptBlob -Value $null | Should -BeNullOrEmpty
            ConvertFrom-AutomateScriptBlob -Value '' | Should -BeNullOrEmpty
        }
    }
}
