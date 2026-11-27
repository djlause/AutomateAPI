function Export-AutomateScript {
    <#
      .SYNOPSIS
        Exports ConnectWise Automate scripts, with their steps, parameters, variables and folders, to readable files.
      .DESCRIPTION
        Reads Automate scripts either straight from the Automate MySQL database (read-only SELECT queries on
        lt_scripts and scriptfolders) or from script XML files exported from the Automate Control Center.
        Each script's steps are decoded from the compressed ScriptData value and written out as:

          Scripts\<Folder>\<Id> - <Name>.md     A readable page: details, variables, and IF / THEN / ELSE steps
          Scripts\<Folder>\<Id> - <Name>.json   The same script as structured data, with every raw parameter
          Scripts\<Folder>\<Id> - <Name>.code\  Embedded PowerShell, batch, VBScript, shell and SQL bodies as files

        and, for the whole export:

          index.csv           One row per script: id, name, folder, type, step count, variables, called scripts
          function-usage.csv  Every step function used, how often and in how many scripts
          folders.csv         The script folder tree
          README.md           Summary of the run and any warnings

        The aim is to make each script easy to read and recreate somewhere else, such as Datto RMM components.
        The output is not meant to be imported back into Automate.
      .PARAMETER Server
        Host name or IP of the Automate MySQL server.
      .PARAMETER Port
        MySQL port. Default 3306.
      .PARAMETER Database
        Automate database name. Default 'labtech'.
      .PARAMETER Credential
        MySQL user name and password. A read-only account is recommended. You are prompted if it is not given.
      .PARAMETER MySqlDataPath
        Full path to MySql.Data.dll (MySQL Connector/NET). If not given, the function looks in the Automate
        Control Center folder, the MySQL Connector/NET install folders and the GAC.
      .PARAMETER ConnectionOptions
        Extra connection string settings, for example 'SslMode=Required'.
      .PARAMETER XmlPath
        Instead of the database, read scripts from Automate script XML exports. Give a file or a folder; every
        .xml file in a folder, and its subfolders, is read.
      .PARAMETER OutputPath
        Folder to write the export to. It is created if needed. Existing files with the same names are overwritten.
      .PARAMETER ScriptId
        Only export these script ids.
      .PARAMETER IncludeRawXml
        Also save each script's decoded ScriptData XML next to its page.
      .PARAMETER PassThru
        Return the exported script objects as well as writing the files.
      .EXAMPLE
        Export-AutomateScript -Server automate-db.contoso.local -Credential (Get-Credential) -OutputPath C:\Temp\AutomateScripts
        Exports every script from the Automate database.
      .EXAMPLE
        Export-AutomateScript -XmlPath C:\Temp\ExportedXml -OutputPath C:\Temp\AutomateScripts
        Decodes scripts that were exported from the Control Center as XML files.
      .EXAMPLE
        Export-AutomateScript -Server 10.0.0.5 -Credential $Cred -OutputPath .\Out -ScriptId 101,202 -PassThru | Select-Object ScriptName, FolderPath
        Exports two scripts and lists them.
      .NOTES
        Version:        0.1.0
        Creation Date:  2026-11-27
        Purpose/Change: First version, for migrating scripts from Automate to Datto RMM.

        Only SELECT statements are run, inside a read-only session. Step names and parameter names come from
        Data\AutomateScriptFunctions.json, derived from the MIT licensed labtech-script-decode project.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Database')]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'Database')]
        [string]
        $Server,

        [Parameter(Mandatory = $false, ParameterSetName = 'Database')]
        [int]
        $Port = 3306,

        [Parameter(Mandatory = $false, ParameterSetName = 'Database')]
        [string]
        $Database = 'labtech',

        [Parameter(Mandatory = $true, ParameterSetName = 'Database')]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential,

        [Parameter(Mandatory = $false, ParameterSetName = 'Database')]
        [string]
        $MySqlDataPath,

        [Parameter(Mandatory = $false, ParameterSetName = 'Database')]
        [string]
        $ConnectionOptions,

        [Parameter(Mandatory = $true, ParameterSetName = 'Xml')]
        [string[]]
        $XmlPath,

        [Parameter(Mandatory = $true)]
        [string]
        $OutputPath,

        [Parameter(Mandatory = $false)]
        [int[]]
        $ScriptId,

        [Parameter(Mandatory = $false)]
        [switch]
        $IncludeRawXml,

        [Parameter(Mandatory = $false)]
        [switch]
        $PassThru
    )

    $ErrorActionPreference = 'Stop'

    # 1. Read script rows and folder rows
    if ($PSCmdlet.ParameterSetName -eq 'Database') {
        $Source = "MySQL database '$Database' on ${Server}:$Port"
        $Data = Get-AutomateScriptRowsFromDatabase -Server $Server -Port $Port -Database $Database -Credential $Credential -MySqlDataPath $MySqlDataPath -ConnectionOptions $ConnectionOptions
    }
    else {
        $Source = "XML export files: $($XmlPath -join ', ')"
        $Data = Get-AutomateScriptRowsFromXml -Path $XmlPath
    }
    $ScriptRows = @($Data.Scripts)
    $FolderRows = @($Data.Folders)
    Write-Verbose "Read $($ScriptRows.Count) scripts and $($FolderRows.Count) folders from $Source"

    $FolderIndex = @{}
    foreach ($Folder in $FolderRows) { $FolderIndex["$($Folder.FolderID)"] = $Folder }

    # Names for every script, so steps that run another script can name it
    $ScriptNameIndex = @{}
    foreach ($Row in $ScriptRows) {
        $Path = Get-AutomateFolderPath -FolderIndex $FolderIndex -FolderId $Row.FolderId
        $FullName = "$($Row.ScriptName)"
        if ($Path) { $FullName = "$Path\$($Row.ScriptName)" }
        $ScriptNameIndex["$($Row.ScriptId)"] = $FullName
        if ($Row.ScriptGuid) { $ScriptNameIndex["$($Row.ScriptGuid)"] = $FullName }
    }

    if ($ScriptId) {
        $ScriptRows = @($ScriptRows | Where-Object { $ScriptId -contains [int]$_.ScriptId })
    }

    # 2. Prepare the output folder
    if (-not (Test-Path -LiteralPath $OutputPath)) { $null = New-Item -ItemType Directory -Path $OutputPath -Force }
    $OutputPath = (Resolve-Path -LiteralPath $OutputPath).ProviderPath
    $ScriptsRoot = Join-Path $OutputPath 'Scripts'
    if (-not (Test-Path -LiteralPath $ScriptsRoot)) { $null = New-Item -ItemType Directory -Path $ScriptsRoot -Force }
    $Utf8 = New-Object System.Text.UTF8Encoding($false)

    # 3. Convert and write each script
    $Index = New-Object System.Collections.ArrayList
    $Usage = @{}
    $AllWarnings = New-Object System.Collections.ArrayList
    $Results = New-Object System.Collections.ArrayList
    $Count = 0
    foreach ($Row in $ScriptRows) {
        $Count++
        Write-Progress -Activity 'Exporting Automate scripts' -Status "$($Row.ScriptName)" -PercentComplete ([int](100 * $Count / [Math]::Max(1, $ScriptRows.Count)))
        try {
            $Script = ConvertTo-AutomateScriptExport -Row $Row -FolderIndex $FolderIndex -ScriptNameIndex $ScriptNameIndex
        }
        catch {
            [void]$AllWarnings.Add("Script $($Row.ScriptId) '$($Row.ScriptName)' failed to convert: $($_.Exception.Message)")
            continue
        }

        $FolderParts = @()
        if ($Script.FolderPath) { $FolderParts = @($Script.FolderPath -split '\\' | ForEach-Object { Get-AutomateSafeFileName -Name $_ }) }
        $TargetFolder = $ScriptsRoot
        foreach ($Part in $FolderParts) { $TargetFolder = Join-Path $TargetFolder $Part }
        if (-not (Test-Path -LiteralPath $TargetFolder)) { $null = New-Item -ItemType Directory -Path $TargetFolder -Force }

        $BaseName = Get-AutomateSafeFileName -Name ("{0} - {1}" -f $Script.ScriptId, $Script.ScriptName)
        $CodeFolderName = "$BaseName.code"
        $MarkdownFile = Join-Path $TargetFolder "$BaseName.md"
        $JsonFile = Join-Path $TargetFolder "$BaseName.json"

        $Markdown = ConvertTo-AutomateScriptMarkdown -Script $Script -CodeFolder $CodeFolderName
        [System.IO.File]::WriteAllText($MarkdownFile, $Markdown, $Utf8)

        $JsonObject = [ordered]@{}
        foreach ($P in $Script.PSObject.Properties) {
            if ($P.Name -eq 'ScriptDataXml') { continue }
            if ($P.Name -eq 'EmbeddedCode') {
                $JsonObject[$P.Name] = @($P.Value | ForEach-Object { [ordered]@{ Step = $_.Step; File = "$CodeFolderName/$($_.File)" } })
                continue
            }
            $JsonObject[$P.Name] = $P.Value
        }
        [System.IO.File]::WriteAllText($JsonFile, (ConvertTo-Json -InputObject $JsonObject -Depth 20), $Utf8)

        if ($Script.EmbeddedCode.Count -gt 0) {
            $CodeFolder = Join-Path $TargetFolder $CodeFolderName
            if (-not (Test-Path -LiteralPath $CodeFolder)) { $null = New-Item -ItemType Directory -Path $CodeFolder -Force }
            foreach ($Code in $Script.EmbeddedCode) {
                [System.IO.File]::WriteAllText((Join-Path $CodeFolder $Code.File), $Code.Text, $Utf8)
            }
        }
        if ($IncludeRawXml -and $Script.ScriptDataXml) {
            [System.IO.File]::WriteAllText((Join-Path $TargetFolder "$BaseName.ScriptData.xml"), $Script.ScriptDataXml, $Utf8)
        }

        foreach ($Step in $Script.Steps) {
            $Key = "$($Step.FunctionId)"
            if (-not $Usage.ContainsKey($Key)) {
                $Usage[$Key] = [ordered]@{ FunctionId = $Step.FunctionId; FunctionName = $Step.FunctionName; FunctionType = $Step.FunctionType; StepCount = 0; Scripts = New-Object System.Collections.ArrayList }
            }
            $Usage[$Key].StepCount++
            if (-not $Usage[$Key].Scripts.Contains("$($Script.ScriptId)")) { [void]$Usage[$Key].Scripts.Add("$($Script.ScriptId)") }
        }
        foreach ($W in $Script.Warnings) { [void]$AllWarnings.Add("Script $($Script.ScriptId) '$($Script.ScriptName)': $W") }

        $RelativePage = $MarkdownFile.Substring($OutputPath.Length).TrimStart('\', '/')
        [void]$Index.Add([pscustomobject][ordered]@{
                ScriptId        = $Script.ScriptId
                ScriptName      = $Script.ScriptName
                FolderPath      = $Script.FolderPath
                ScriptTypes     = $Script.ScriptTypes -join ', '
                StepCount       = $Script.Steps.Count
                DisabledSteps   = @($Script.Steps | Where-Object { $_.Disabled }).Count
                EmbeddedCode    = $Script.EmbeddedCode.Count
                VariablesSet    = $Script.VariablesSet -join ', '
                VariablesUsed   = $Script.VariablesUsed -join ', '
                SystemVariables = $Script.SystemVariables -join ', '
                CalledScripts   = $Script.CalledScripts -join ' | '
                Functions       = (@($Script.Steps | ForEach-Object { $_.FunctionName } | Select-Object -Unique) -join ' | ')
                Warnings        = $Script.Warnings.Count
                ScriptGuid      = $Script.ScriptGuid
                LastUser        = $Script.Metadata['Last_User']
                LastDate        = $Script.Metadata['Last_Date']
                Page            = $RelativePage
            })
        if ($PassThru) { [void]$Results.Add($Script) }
    }
    Write-Progress -Activity 'Exporting Automate scripts' -Completed

    # 4. Whole-export files
    $Index | Sort-Object FolderPath, ScriptName | Export-Csv -LiteralPath (Join-Path $OutputPath 'index.csv') -NoTypeInformation -Encoding UTF8

    $UsageRows = foreach ($U in $Usage.Values) {
        [pscustomobject][ordered]@{
            FunctionId    = $U.FunctionId
            FunctionName  = $U.FunctionName
            FunctionType  = $U.FunctionType
            StepCount     = $U.StepCount
            ScriptCount   = $U.Scripts.Count
            ExampleScripts = (@($U.Scripts | Select-Object -First 5 | ForEach-Object { $ScriptNameIndex[$_] }) -join ' | ')
        }
    }
    @($UsageRows) | Sort-Object @{ Expression = 'ScriptCount'; Descending = $true }, FunctionName |
        Export-Csv -LiteralPath (Join-Path $OutputPath 'function-usage.csv') -NoTypeInformation -Encoding UTF8

    $FolderOut = foreach ($Folder in $FolderRows) {
        [pscustomobject][ordered]@{
            FolderID = $Folder.FolderID
            ParentID = $Folder.ParentID
            Name     = $Folder.Name
            Path     = Get-AutomateFolderPath -FolderIndex $FolderIndex -FolderId $Folder.FolderID
            GUID     = $Folder.GUID
        }
    }
    @($FolderOut) | Sort-Object Path | Export-Csv -LiteralPath (Join-Path $OutputPath 'folders.csv') -NoTypeInformation -Encoding UTF8

    $TotalSteps = ($Index | Measure-Object -Property StepCount -Sum).Sum
    $Summary = New-Object System.Text.StringBuilder
    [void]$Summary.AppendLine('# Automate script export')
    [void]$Summary.AppendLine()
    [void]$Summary.AppendLine("- Exported: $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    [void]$Summary.AppendLine("- Source: $Source")
    [void]$Summary.AppendLine("- Scripts: $($Index.Count)")
    [void]$Summary.AppendLine("- Folders: $($FolderRows.Count)")
    [void]$Summary.AppendLine("- Steps: $TotalSteps")
    [void]$Summary.AppendLine("- Distinct step functions: $($Usage.Count) (see function-usage.csv)")
    [void]$Summary.AppendLine("- Scripts with embedded code: $(@($Index | Where-Object { $_.EmbeddedCode -gt 0 }).Count)")
    [void]$Summary.AppendLine()
    [void]$Summary.AppendLine('Each script has a readable .md page and a .json file under Scripts\, in the same folder tree as Automate. index.csv lists every script.')
    [void]$Summary.AppendLine()
    [void]$Summary.AppendLine("## Warnings ($($AllWarnings.Count))")
    [void]$Summary.AppendLine()
    if ($AllWarnings.Count -eq 0) { [void]$Summary.AppendLine('None.') }
    foreach ($W in $AllWarnings) { [void]$Summary.AppendLine("- $W") }
    [System.IO.File]::WriteAllText((Join-Path $OutputPath 'README.md'), $Summary.ToString(), $Utf8)

    Write-Verbose "Exported $($Index.Count) scripts to $OutputPath with $($AllWarnings.Count) warnings"
    foreach ($W in $AllWarnings) { Write-Warning $W }

    if ($PassThru) { return $Results }
}

function Get-AutomateSafeFileName {
    # Makes a string safe to use as a Windows file or folder name
    param ([string]$Name, [int]$MaxLength = 100)
    $Invalid = [regex]::Escape((-join [System.IO.Path]::GetInvalidFileNameChars()) + '\/:*?"<>|')
    $Safe = ($Name -replace "[$Invalid]", '_').Trim().TrimEnd('.')
    if ($Safe.Length -gt $MaxLength) { $Safe = $Safe.Substring(0, $MaxLength).Trim() }
    if (-not $Safe) { $Safe = '_' }
    if ($Safe -match '^(CON|PRN|AUX|NUL|COM\d|LPT\d)$') { $Safe = "_$Safe" }
    return $Safe
}

function Get-AutomateScriptRowsFromDatabase {
    # Reads lt_scripts and scriptfolders with read-only SELECT queries
    param ($Server, $Port, $Database, [System.Management.Automation.PSCredential]$Credential, $MySqlDataPath, $ConnectionOptions)

    Import-AutomateMySqlData -Path $MySqlDataPath

    $Builder = New-Object System.Text.StringBuilder
    [void]$Builder.Append("Server=$Server;Port=$Port;Database=$Database;")
    [void]$Builder.Append("Uid=$($Credential.UserName);Pwd=$($Credential.GetNetworkCredential().Password);")
    # Automate has zero dates in some tables; this keeps them from throwing
    [void]$Builder.Append('Convert Zero Datetime=True;Default Command Timeout=300;')
    if ($ConnectionOptions) { [void]$Builder.Append($ConnectionOptions.TrimEnd(';') + ';') }

    $Connection = New-Object MySql.Data.MySqlClient.MySqlConnection($Builder.ToString())
    try {
        $Connection.Open()
        Invoke-AutomateMySqlQuery -Connection $Connection -Query 'SET SESSION TRANSACTION READ ONLY' -NonQuery
        $Scripts = Invoke-AutomateMySqlQuery -Connection $Connection -Query 'SELECT * FROM lt_scripts ORDER BY ScriptId'
        $Folders = Invoke-AutomateMySqlQuery -Connection $Connection -Query 'SELECT * FROM scriptfolders ORDER BY FolderID'
    }
    finally {
        $Connection.Dispose()
    }
    return @{ Scripts = $Scripts; Folders = $Folders }
}

function Invoke-AutomateMySqlQuery {
    param ($Connection, [string]$Query, [switch]$NonQuery)
    $Command = $Connection.CreateCommand()
    $Command.CommandText = $Query
    try {
        if ($NonQuery) { [void]$Command.ExecuteNonQuery(); return }
        $Reader = $Command.ExecuteReader()
        $Rows = New-Object System.Collections.ArrayList
        try {
            while ($Reader.Read()) {
                $Row = [ordered]@{}
                for ($i = 0; $i -lt $Reader.FieldCount; $i++) {
                    $Value = $Reader.GetValue($i)
                    if ($Value -is [System.DBNull]) { $Value = $null }
                    $Row[$Reader.GetName($i)] = $Value
                }
                [void]$Rows.Add([pscustomobject]$Row)
            }
        }
        finally { $Reader.Dispose() }
        return $Rows
    }
    finally { $Command.Dispose() }
}

function Import-AutomateMySqlData {
    # Loads MySql.Data.dll (MySQL Connector/NET) if it is not loaded already
    param ([string]$Path)
    if ('MySql.Data.MySqlClient.MySqlConnection' -as [type]) { return }

    $Candidates = @()
    if ($Path) { $Candidates += $Path }
    # Assumption: the Automate Control Center and the Automate server ship MySql.Data.dll in these folders
    foreach ($ProgramFolder in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if (-not $ProgramFolder) { continue }
        $Candidates += (Join-Path $ProgramFolder 'LabTech Client\MySql.Data.dll')
        $Candidates += (Join-Path $ProgramFolder 'LabTech\MySql.Data.dll')
    }
    foreach ($ProgramFolder in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if (-not $ProgramFolder) { continue }
        $Root = Join-Path $ProgramFolder 'MySQL'
        if (Test-Path -LiteralPath $Root) {
            $Candidates += @(Get-ChildItem -Path $Root -Filter 'MySql.Data.dll' -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName)
        }
    }

    foreach ($Candidate in $Candidates) {
        if ($Candidate -and (Test-Path -LiteralPath $Candidate)) {
            try {
                Add-Type -Path $Candidate
                Write-Verbose "Loaded MySQL connector from $Candidate"
                return
            }
            catch {
                Write-Verbose "Could not load $Candidate : $($_.Exception.Message)"
            }
        }
    }
    try {
        $Assembly = [System.Reflection.Assembly]::LoadWithPartialName('MySql.Data')
        if ($Assembly) { return }
    }
    catch { }

    throw ("MySql.Data.dll (MySQL Connector/NET) was not found. Install it from https://dev.mysql.com/downloads/connector/net/ " +
        "or pass its location with -MySqlDataPath. The Automate Control Center folder usually has a copy.")
}

function Get-AutomateScriptRowsFromXml {
    # Reads script tables and folder tables from Automate script XML exports (LabTech_Expansion files)
    param ([string[]]$Path)

    $Files = foreach ($P in $Path) {
        if (Test-Path -LiteralPath $P -PathType Container) {
            Get-ChildItem -LiteralPath $P -Filter '*.xml' -Recurse -File
        }
        elseif (Test-Path -LiteralPath $P) {
            Get-Item -LiteralPath $P
        }
        else {
            throw "Path not found: $P"
        }
    }

    $Scripts = [ordered]@{}
    $Folders = [ordered]@{}
    foreach ($File in $Files) {
        try {
            $Doc = New-Object System.Xml.XmlDocument
            $Doc.PreserveWhitespace = $false
            $Doc.Load($File.FullName)
        }
        catch {
            Write-Warning "Skipped $($File.FullName): not valid XML ($($_.Exception.Message))"
            continue
        }
        if ($Doc.DocumentElement.get_LocalName() -ne 'LabTech_Expansion') {
            Write-Verbose "Skipped $($File.FullName): not an Automate script export"
            continue
        }
        # Nested PackedScript elements hold scripts that the main script calls
        foreach ($Table in $Doc.SelectNodes('//PackedScript/NewDataSet/Table')) {
            $Row = [ordered]@{}
            foreach ($Child in $Table.ChildNodes) {
                if ($Child.NodeType -eq [System.Xml.XmlNodeType]::Element) { $Row[$Child.get_LocalName()] = $Child.InnerText.Trim() }
            }
            $Key = "$($Row['ScriptGuid'])"
            if (-not $Key) { $Key = "id:$($Row['ScriptId'])" }
            if (-not $Scripts.Contains($Key)) { $Scripts[$Key] = [pscustomobject]$Row }
        }
        foreach ($Table in $Doc.SelectNodes('//ScriptFolder/NewDataSet/Table')) {
            $Row = [ordered]@{}
            foreach ($Child in $Table.ChildNodes) {
                if ($Child.NodeType -eq [System.Xml.XmlNodeType]::Element) { $Row[$Child.get_LocalName()] = $Child.InnerText.Trim() }
            }
            if (-not $Folders.Contains("$($Row['FolderID'])")) { $Folders["$($Row['FolderID'])"] = [pscustomobject]$Row }
        }
    }
    return @{ Scripts = @($Scripts.Values); Folders = @($Folders.Values) }
}
