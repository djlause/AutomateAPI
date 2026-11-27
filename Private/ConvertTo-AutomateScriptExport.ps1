function Get-AutomateScriptCatalog {
    <#
      .SYNOPSIS
        Loads the Automate script function catalog (step function names, parameter names, value lists).
      .NOTES
        The catalog in Data\AutomateScriptFunctions.json is derived from the MIT licensed
        labtech-script-decode project by Kevin Grube. See Data\THIRD-PARTY-NOTICES.md.
    #>
    [CmdletBinding()]
    param ()
    if (-not $Script:AutomateScriptCatalog) {
        $Path = Join-Path (Split-Path $PSScriptRoot -Parent) 'Data\AutomateScriptFunctions.json'
        if (-not (Test-Path $Path)) {
            $Path = Join-Path (Split-Path $PSScriptRoot -Parent) 'Data/AutomateScriptFunctions.json'
        }
        $Script:AutomateScriptCatalog = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    return $Script:AutomateScriptCatalog
}

function Get-AutomateCatalogEntry {
    # Reads a numbered entry such as Functions.20 or OsLimits.-2147483648 from the catalog
    param ($Section, $Key)
    if ($null -eq $Section -or $null -eq $Key) { return $null }
    $Property = $Section.PSObject.Properties["$Key"]
    if ($Property) { return $Property.Value }
    return $null
}

function ConvertFrom-AutomateXmlNode {
    # Turns an XmlNode into strings, ordered hashtables and arrays so it can be written as JSON
    param ($Node)
    if ($null -eq $Node) { return $null }
    if ($Node -is [string]) { return $Node }
    $Elements = @($Node.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element })
    if ($Elements.Count -eq 0) {
        $Text = $Node.InnerText
        if ($Text -eq '') { return $null }
        return $Text
    }
    $Result = [ordered]@{}
    foreach ($Child in $Elements) {
        $Value = ConvertFrom-AutomateXmlNode -Node $Child
        if ($Result.Contains($Child.get_LocalName())) {
            if ($Result[$Child.get_LocalName()] -isnot [System.Collections.ArrayList]) {
                $List = New-Object System.Collections.ArrayList
                [void]$List.Add($Result[$Child.get_LocalName()])
                $Result[$Child.get_LocalName()] = $List
            }
            [void]$Result[$Child.get_LocalName()].Add($Value)
        }
        else {
            $Result[$Child.get_LocalName()] = $Value
        }
    }
    return $Result
}

function Get-AutomateFolderPath {
    # Builds "Parent\Child" folder paths from scriptfolders rows (FolderID, ParentID, Name)
    param ([hashtable]$FolderIndex, $FolderId)
    $Parts = @()
    $Seen = @{}
    $Current = "$FolderId"
    while ($Current -and $Current -ne '0' -and $FolderIndex.ContainsKey($Current) -and -not $Seen.ContainsKey($Current)) {
        $Seen[$Current] = $true
        $Folder = $FolderIndex[$Current]
        $Parts = , "$($Folder.Name)" + $Parts
        $Current = "$($Folder.ParentID)"
    }
    return ($Parts -join '\')
}

function Get-AutomateStepDescription {
    # Writes one readable line for a script step
    param ($Step, $FunctionDef, [string[]]$ParamValues, [hashtable]$ScriptNameIndex, $Catalog)

    $FunctionId = [int]$Step.FunctionId
    if (-not $FunctionDef) {
        $Shown = @($ParamValues | Where-Object { $_ -ne '' } | ForEach-Object { "'$_'" })
        return "Unknown function $FunctionId $($Shown -join ', ')".Trim()
    }

    switch ($FunctionId) {
        139 {
            if ("$($ParamValues[0])".StartsWith(':')) { return "$($ParamValues[0]) - Label" }
            return "Note: $($ParamValues[0])"
        }
        2 {
            $Command = Get-AutomateCatalogEntry -Section $Catalog.RemoteCommands -Key $ParamValues[0]
            if (-not $Command) { $Command = "command $($ParamValues[0])" }
            return "LabTech Command: $Command $($ParamValues[1])".Trim()
        }
    }

    $Pieces = @()
    for ($i = 0; $i -lt @($FunctionDef.ParamNames).Count -and $i -lt 5; $i++) {
        $ParamDef = @($FunctionDef.ParamNames)[$i]
        $Raw = $ParamValues[$i]
        if ($null -eq $Raw -or $Raw -eq '') { continue }
        $Shown = Resolve-AutomateParamValue -FunctionId $FunctionId -ParamIndex $i -ParamDef $ParamDef -Raw $Raw -ScriptNameIndex $ScriptNameIndex
        if ($Shown -match "`n") { $Shown = '(multi-line, see below)' }
        $Label = $ParamDef.ParamName
        if (-not $Label) { $Label = "Param$($i + 1)" }
        $Pieces += "$Label=$Shown"
    }
    $Prefix = $FunctionDef.Name
    if ($FunctionDef.FunctionType -eq 1 -and $Prefix -notmatch '^IF ') { $Prefix = "IF $Prefix" }
    if ($Pieces.Count -eq 0) { return $Prefix }
    return "${Prefix}: $($Pieces -join '; ')"
}

function Resolve-AutomateParamValue {
    # Turns a raw step parameter into readable text where the catalog gives a value list,
    # or where it points at another script
    param ($FunctionId, $ParamIndex, $ParamDef, $Raw, [hashtable]$ScriptNameIndex)

    $ScriptRefFunctions = @{ 17 = 0; 92 = 0; 146 = 1; 251 = 0 }
    if ($ScriptRefFunctions.ContainsKey([int]$FunctionId) -and $ScriptRefFunctions[[int]$FunctionId] -eq $ParamIndex) {
        $Key = "$Raw".Trim(':')
        if ($ScriptNameIndex -and $ScriptNameIndex.ContainsKey($Key)) {
            return "[$($ScriptNameIndex[$Key])] (script $Raw)"
        }
        return "script $Raw"
    }

    $Values = @($ParamDef.Values)
    if ($ParamDef.Values -and $Values.Count -gt 0 -and "$($Values[0])" -notmatch '^\s*select\s') {
        $Index = 0
        if ([int]::TryParse("$Raw", [ref]$Index) -and $Index -ge 0 -and $Index -lt $Values.Count) {
            return $Values[$Index]
        }
    }
    return "$Raw"
}

function Get-AutomateEmbeddedCode {
    # Says whether a step carries a code body worth saving as its own file, and which extension it gets
    param ($FunctionId, [string[]]$ParamValues)
    switch ([int]$FunctionId) {
        235 {
            $Extension = switch ("$($ParamValues[0])") { '1' { 'vbs' } '2' { 'bat' } default { 'ps1' } }
            return @{ Text = $ParamValues[1]; Extension = $Extension; Param = 2 }
        }
        { $_ -in 135, 203 } { return @{ Text = $ParamValues[0]; Extension = 'ps1'; Param = 1 } }
        { $_ -in 16, 109, 126, 128, 169 } {
            if ("$($ParamValues[0])" -match "`n" -or "$($ParamValues[0])".Length -gt 200) {
                return @{ Text = $ParamValues[0]; Extension = 'cmd.txt'; Param = 1 }
            }
        }
        { $_ -in 11, 67, 117, 146, 172, 196 } {
            if ("$($ParamValues[0])" -match "`n" -or "$($ParamValues[0])".Length -gt 200) {
                return @{ Text = $ParamValues[0]; Extension = 'sql'; Param = 1 }
            }
        }
    }
    return $null
}

function ConvertTo-AutomateScriptExport {
    <#
      .SYNOPSIS
        Turns one lt_scripts row (or the Table of an exported script) into a readable script object.
      .PARAMETER Row
        An object with lt_scripts columns: ScriptId, ScriptName, FolderId, ScriptData, LicenseData and so on.
      .PARAMETER FolderIndex
        Hashtable of FolderID (string) to folder row, used to build the folder path.
      .PARAMETER ScriptNameIndex
        Hashtable of ScriptId and ScriptGuid (strings) to "Folder\Script name", used to name called scripts.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        $Row,
        [hashtable]$FolderIndex = @{},
        [hashtable]$ScriptNameIndex = @{}
    )

    $Catalog = Get-AutomateScriptCatalog
    $BlobColumns = @('ScriptData', 'LicenseData')
    $Warnings = New-Object System.Collections.ArrayList

    # Every non-blob column is kept as metadata, so columns this tool does not know about still come through
    $Metadata = [ordered]@{}
    foreach ($Property in $Row.PSObject.Properties) {
        if ($BlobColumns -contains $Property.Name) { continue }
        $Value = $Property.Value
        if ($Value -is [System.DBNull]) { $Value = $null }
        if ($Value -is [byte[]]) { $Value = [System.Convert]::ToBase64String($Value) }
        if ($Value -is [datetime]) { $Value = $Value.ToString('yyyy-MM-dd HH:mm:ss') }
        $Metadata[$Property.Name] = $Value
    }

    $ScriptXml = $null
    $LicenseXml = $null
    try { $ScriptXml = ConvertFrom-AutomateScriptBlob -Value $Row.ScriptData }
    catch { [void]$Warnings.Add("ScriptData could not be decoded: $($_.Exception.Message)") }
    try { $LicenseXml = ConvertFrom-AutomateScriptBlob -Value $Row.LicenseData }
    catch { [void]$Warnings.Add("LicenseData could not be decoded: $($_.Exception.Message)") }

    $ScriptHeader = $null
    $License = $null
    $Steps = New-Object System.Collections.ArrayList
    $EmbeddedCode = New-Object System.Collections.ArrayList
    $VariablesUsed = @{}
    $VariablesSet = @{}
    $SystemVariables = @{}
    $CalledScripts = @{}

    if ($LicenseXml) {
        try { $License = ConvertFrom-AutomateXmlNode -Node ([xml]$LicenseXml).DocumentElement }
        catch { [void]$Warnings.Add("LicenseData is not valid XML: $($_.Exception.Message)") }
    }

    if ($ScriptXml) {
        try {
            $Doc = [xml]$ScriptXml
            $ScriptHeader = ConvertFrom-AutomateXmlNode -Node $Doc.DocumentElement.SelectSingleNode('Scripts')
            $StepNodes = @($Doc.DocumentElement.SelectNodes('ScriptSteps'))
            $RawSteps = foreach ($Node in $StepNodes) {
                $S = [ordered]@{}
                foreach ($Name in 'Action', 'FunctionId', 'Param1', 'Param2', 'Param3', 'Param4', 'Param5', 'Sort', 'Continue', 'OsLimit', 'Indentation') {
                    $Child = $Node.SelectSingleNode($Name)
                    if ($Child) { $S[$Name] = $Child.InnerText } else { $S[$Name] = '' }
                }
                [pscustomobject]$S
            }
            # Same order Automate shows: the IF check first, then THEN and ELSE steps by Sort
            $RawSteps = @($RawSteps | Sort-Object @{ Expression = { [int]("0$($_.Action)") } }, @{ Expression = { [int]("0$($_.Sort)") } })

            $LineNumber = 0
            foreach ($Raw in $RawSteps) {
                $LineNumber++
                $FunctionId = [int]("0$($Raw.FunctionId)")
                $FunctionDef = Get-AutomateCatalogEntry -Section $Catalog.Functions -Key $FunctionId
                $ParamValues = [string[]]@($Raw.Param1, $Raw.Param2, $Raw.Param3, $Raw.Param4, $Raw.Param5)

                $Section = Get-AutomateCatalogEntry -Section $Catalog.Actions -Key $Raw.Action
                if (-not $Section) { $Section = "Action$($Raw.Action)" }
                $OsLimit = Get-AutomateCatalogEntry -Section $Catalog.OsLimits -Key $Raw.OsLimit
                $OnFailure = Get-AutomateCatalogEntry -Section $Catalog.Continues -Key $Raw.Continue

                $Parameters = [ordered]@{}
                for ($i = 0; $i -lt 5; $i++) {
                    $ParamDef = $null
                    if ($FunctionDef -and $i -lt @($FunctionDef.ParamNames).Count) { $ParamDef = @($FunctionDef.ParamNames)[$i] }
                    if ($ParamValues[$i] -eq '' -and -not $ParamDef) { continue }
                    $Label = "Param$($i + 1)"
                    if ($ParamDef -and $ParamDef.ParamName) { $Label = "Param$($i + 1) ($($ParamDef.ParamName))" }
                    $Display = $ParamValues[$i]
                    if ($ParamDef -and $ParamValues[$i] -ne '') {
                        $Display = Resolve-AutomateParamValue -FunctionId $FunctionId -ParamIndex $i -ParamDef $ParamDef -Raw $ParamValues[$i] -ScriptNameIndex $ScriptNameIndex
                    }
                    $Parameters[$Label] = [ordered]@{ Raw = $ParamValues[$i]; Display = $Display }
                }

                if (-not $FunctionDef) {
                    $SectionTitle = switch ($Section) { 'InitialCheck' { 'IF' } 'ThenSection' { 'THEN' } 'ElseSection' { 'ELSE' } default { $Section } }
                    [void]$Warnings.Add("$SectionTitle step $([int]("0$($Raw.Sort)") + 1) uses function $FunctionId, which is not in the catalog.")
                }

                $Code = Get-AutomateEmbeddedCode -FunctionId $FunctionId -ParamValues $ParamValues
                $CodeFile = $null
                if ($Code -and $Code.Text) {
                    $CodeFile = '{0}-{1:D2}.{2}' -f ($Section -replace 'Section$', '' -replace 'InitialCheck', 'If'), ([int]("0$($Raw.Sort)") + 1), $Code.Extension
                    [void]$EmbeddedCode.Add([ordered]@{ Step = $LineNumber; File = $CodeFile; Text = $Code.Text })
                }

                # Variables: @name@ are script variables, %name% are Automate system variables
                foreach ($Value in $ParamValues) {
                    foreach ($M in [regex]::Matches("$Value", '@([A-Za-z0-9_.\-]+)@')) { $VariablesUsed[$M.Groups[1].Value] = $true }
                    foreach ($M in [regex]::Matches("$Value", '%([A-Za-z0-9_\-]+)%')) { $SystemVariables[$M.Groups[1].Value] = $true }
                }
                if ($FunctionDef) {
                    for ($i = 0; $i -lt @($FunctionDef.ParamNames).Count -and $i -lt 5; $i++) {
                        $PName = "$(@($FunctionDef.ParamNames)[$i].ParamName)"
                        if ($PName -match '^(Variable|Variable Name|Variable List)$' -and $ParamValues[$i] -ne '') {
                            foreach ($V in ($ParamValues[$i] -split '[,|]')) { if ($V.Trim()) { $VariablesSet[$V.Trim().Trim('@')] = $true } }
                        }
                    }
                }
                if (@(17, 92, 251) -contains $FunctionId -and $ParamValues[0]) { $CalledScripts[(Resolve-AutomateParamValue -FunctionId $FunctionId -ParamIndex 0 -ParamDef $null -Raw $ParamValues[0] -ScriptNameIndex $ScriptNameIndex)] = $true }
                if ($FunctionId -eq 146 -and $ParamValues[1]) { $CalledScripts[(Resolve-AutomateParamValue -FunctionId 146 -ParamIndex 1 -ParamDef $null -Raw $ParamValues[1] -ScriptNameIndex $ScriptNameIndex)] = $true }

                $FunctionName = "Unknown function $FunctionId"
                $FunctionType = $null
                if ($FunctionDef) {
                    $FunctionName = $FunctionDef.Name
                    $FunctionType = Get-AutomateCatalogEntry -Section $Catalog.FunctionTypes -Key $FunctionDef.FunctionType
                }

                [void]$Steps.Add([ordered]@{
                        Line         = $LineNumber
                        Section      = $Section
                        Sort         = [int]("0$($Raw.Sort)")
                        Indentation  = [int]("0$($Raw.Indentation)")
                        FunctionId   = $FunctionId
                        FunctionName = $FunctionName
                        FunctionType = $FunctionType
                        Description  = Get-AutomateStepDescription -Step $Raw -FunctionDef $FunctionDef -ParamValues $ParamValues -ScriptNameIndex $ScriptNameIndex -Catalog $Catalog
                        OnFailure    = $OnFailure
                        OsLimit      = $OsLimit
                        Disabled     = ([int64]("0$($Raw.OsLimit)" -replace '^0-', '-') -lt 0)
                        CodeFile     = $CodeFile
                        Parameters   = $Parameters
                    })
            }
        }
        catch {
            [void]$Warnings.Add("ScriptData could not be parsed: $($_.Exception.Message)")
        }
    }
    else {
        [void]$Warnings.Add('Script has no ScriptData (no steps).')
    }

    $Types = @()
    if ("$($Row.ComputerScript)" -eq '1') { $Types += 'Computer' }
    if ("$($Row.LocationScript)" -eq '1') { $Types += 'Location' }
    if ("$($Row.MaintenanceScript)" -eq '1') { $Types += 'Maintenance' }
    if ("$($Row.FunctionScript)" -eq '1') { $Types += 'Function' }

    $FolderPath = Get-AutomateFolderPath -FolderIndex $FolderIndex -FolderId $Row.FolderId

    return [pscustomobject][ordered]@{
        ScriptId        = $Row.ScriptId
        ScriptName      = $Row.ScriptName
        ScriptGuid      = $Row.ScriptGuid
        FolderId        = $Row.FolderId
        FolderPath      = $FolderPath
        ScriptTypes     = $Types
        Notes           = $Row.ScriptNotes
        Metadata        = $Metadata
        Header          = $ScriptHeader
        License         = $License
        VariablesSet    = @($VariablesSet.Keys | Sort-Object)
        VariablesUsed   = @($VariablesUsed.Keys | Sort-Object)
        SystemVariables = @($SystemVariables.Keys | Sort-Object)
        CalledScripts   = @($CalledScripts.Keys | Sort-Object)
        Steps           = $Steps
        EmbeddedCode    = $EmbeddedCode
        Warnings        = $Warnings
        ScriptDataXml   = $ScriptXml
    }
}

function ConvertTo-AutomateScriptMarkdown {
    # Writes the readable Markdown page for one exported script.
    # CodeFolder is the folder name, next to the page, where embedded code files are saved.
    param ($Script, [string]$CodeFolder = '')

    $NL = "`r`n"
    $Out = New-Object System.Text.StringBuilder
    function Add-Line ([string]$Text = '') { [void]$Out.Append($Text + $NL) }
    function Format-Cell ($Value) { return ("$Value" -replace '\|', '\|' -replace "`r?`n", '<br>') }

    Add-Line "# $($Script.ScriptName)"
    Add-Line
    Add-Line '| Field | Value |'
    Add-Line '| --- | --- |'
    Add-Line "| Script ID | $($Script.ScriptId) |"
    Add-Line "| GUID | $($Script.ScriptGuid) |"
    Add-Line "| Folder | $(Format-Cell $Script.FolderPath) |"
    Add-Line "| Script type | $(($Script.ScriptTypes -join ', ')) |"
    foreach ($Key in 'ScriptVersion', 'Permission', 'EditPermission', 'ScriptFlags', 'Last_User', 'Last_Date') {
        if ($Script.Metadata.Contains($Key) -and "$($Script.Metadata[$Key])" -ne '') {
            Add-Line "| $Key | $(Format-Cell $Script.Metadata[$Key]) |"
        }
    }
    Add-Line "| Steps | $($Script.Steps.Count) |"
    Add-Line

    if ("$($Script.Notes)".Trim()) {
        Add-Line '## Notes'
        Add-Line
        Add-Line "$($Script.Notes)".Trim()
        Add-Line
    }

    if ($Script.Warnings.Count -gt 0) {
        Add-Line '## Export warnings'
        Add-Line
        foreach ($W in $Script.Warnings) { Add-Line "- $W" }
        Add-Line
    }

    $HeaderParts = @()
    if ($Script.Header) {
        foreach ($Key in 'Parameters', 'Globals', 'ExtraDataFields') {
            if ($Script.Header.Contains($Key) -and $null -ne $Script.Header[$Key]) { $HeaderParts += $Key }
        }
    }
    if ("$($Script.Metadata['Parameters'])".Trim()) {
        Add-Line '## Script parameters (lt_scripts.Parameters)'
        Add-Line
        Add-Line '```'
        Add-Line "$($Script.Metadata['Parameters'])".Trim()
        Add-Line '```'
        Add-Line
    }
    foreach ($Key in $HeaderParts) {
        Add-Line "## $Key"
        Add-Line
        Add-Line '```json'
        Add-Line (ConvertTo-Json -InputObject $Script.Header[$Key] -Depth 20)
        Add-Line '```'
        Add-Line
    }

    Add-Line '## Variables'
    Add-Line
    function Format-List ($Items, [string]$Wrap = '') {
        if (@($Items).Count -eq 0) { return 'none' }
        return (@($Items | ForEach-Object { '`' + $Wrap + $_ + $Wrap + '`' }) -join ', ')
    }
    Add-Line ('- Set by this script: ' + (Format-List $Script.VariablesSet))
    Add-Line ('- Script variables used (@name@): ' + (Format-List $Script.VariablesUsed '@'))
    Add-Line ('- Automate variables used (%name%): ' + (Format-List $Script.SystemVariables '%'))
    if ($Script.CalledScripts.Count) {
        Add-Line "- Calls other scripts: $(($Script.CalledScripts | ForEach-Object { Format-Cell $_ }) -join ', ')"
    }
    Add-Line

    foreach ($SectionName in 'InitialCheck', 'ThenSection', 'ElseSection') {
        $SectionSteps = @($Script.Steps | Where-Object { $_.Section -eq $SectionName })
        if ($SectionSteps.Count -eq 0) { continue }
        $Title = switch ($SectionName) { 'InitialCheck' { 'IF (initial check)' } 'ThenSection' { 'THEN' } 'ElseSection' { 'ELSE' } }
        Add-Line "## $Title"
        Add-Line
        foreach ($Step in $SectionSteps) {
            $Flags = @()
            if ($Step.Disabled) { $Flags += 'DISABLED' }
            if ($Step.OnFailure -and $Step.OnFailure -ne 'Exit on failure') { $Flags += $Step.OnFailure }
            $Os = "$($Step.OsLimit)" -replace '^Function disabled( - )?', ''
            if ($Os -and $Os -ne 'All Operating Systems' -and $Os -ne 'Function disabled') { $Flags += "OS: $Os" }
            $FlagText = ''
            if ($Flags.Count) { $FlagText = " _[$($Flags -join '; ')]_" }
            # Automate's indentation is shown with non-breaking spaces so Markdown does not turn it into nested lists
            $Indent = '&nbsp;&nbsp;&nbsp;&nbsp;' * [Math]::Max(0, $Step.Indentation)
            $Description = ("$($Step.Description)" -replace "`r?`n", ' ')
            Add-Line ("{0}. {1}``{2}``{3}" -f ($Step.Sort + 1), $Indent, $Description, $FlagText)
            $Indent = ''  # lines below continue the list item
            if ($Step.CodeFile) {
                $Link = $Step.CodeFile
                if ($CodeFolder) { $Link = "$CodeFolder/$($Step.CodeFile)" }
                Add-Line "$Indent    Code saved to [$($Step.CodeFile)]($($Link -replace " ", "%20"))"
            }
            else {
                foreach ($P in $Step.Parameters.Values) {
                    if ("$($P.Raw)" -match "`n") {
                        Add-Line "$Indent    ``````"
                        foreach ($L in ("$($P.Raw)" -split "`r?`n")) { Add-Line "$Indent    $L" }
                        Add-Line "$Indent    ``````"
                    }
                }
            }
        }
        Add-Line
    }

    return $Out.ToString()
}
