---
external help file: AutomateAPI-help.xml
Module Name: AutomateAPI
online version:
schema: 2.0.0
---

# Export-AutomateScript

## SYNOPSIS
Exports ConnectWise Automate scripts, with their steps, parameters, variables and folders, to readable files.

## SYNTAX

### Database (Default)
```
Export-AutomateScript -Server <String> [-Port <Int32>] [-Database <String>] -Credential <PSCredential>
 [-MySqlDataPath <String>] [-ConnectionOptions <String>] -OutputPath <String> [-ScriptId <Int32[]>]
 [-IncludeRawXml] [-PassThru] [<CommonParameters>]
```

### Xml
```
Export-AutomateScript -XmlPath <String[]> -OutputPath <String> [-ScriptId <Int32[]>] [-IncludeRawXml]
 [-PassThru] [<CommonParameters>]
```

## DESCRIPTION
Reads every Automate script either straight from the Automate MySQL database or from script XML files
exported from the Automate Control Center, decodes the compressed step data, and writes each script out
as a readable Markdown page and a JSON file, in the same folder tree as Automate.

It was written to help recreate Automate scripts in another RMM, such as Datto RMM. The output is for
people (and tools) to read. It cannot be imported back into Automate.

### What you get

```
<OutputPath>\
  README.md             Summary of the run: counts, source and every warning
  index.csv             One row per script: id, name, folder, type, step count, variables, called scripts, functions used
  function-usage.csv    Every step function used, how many steps and scripts use it, with examples
  folders.csv           The Automate script folder tree
  Scripts\<Folder>\<Subfolder>\
    <Id> - <Name>.md    Details, notes, parameters, variables, and the IF / THEN / ELSE steps in plain words
    <Id> - <Name>.json  The same, as data, with every raw step parameter
    <Id> - <Name>.code\ Embedded PowerShell (.ps1), batch (.bat), VBScript (.vbs), long shell commands and SQL
```

Each step shows its function name and named parameters, with numeric choices turned into words (for
example `Variable Set: Set Type=Constant; Parameter=C:\Tools; Variable Name=InstallDir`). Steps that run
another script name that script. Disabled steps, "Continue on failure" and OS limits are flagged.
The variables section lists script variables the script sets, `@variables@` it uses and the Automate
`%variables%` it relies on, which are the parts that need a Datto RMM equivalent.

`function-usage.csv` is the best place to start planning: it shows which Automate step functions you
actually use, so you can decide how each one maps to Datto RMM before rebuilding scripts.

### How the database read works
Only `SELECT * FROM lt_scripts` and `SELECT * FROM scriptfolders` are run, after
`SET SESSION TRANSACTION READ ONLY`. A MySQL account with SELECT rights on those two tables is enough:

```sql
CREATE USER 'scriptexport'@'%' IDENTIFIED BY '<password>';
GRANT SELECT ON labtech.lt_scripts TO 'scriptexport'@'%';
GRANT SELECT ON labtech.scriptfolders TO 'scriptexport'@'%';
```

The function needs MySql.Data.dll (MySQL Connector/NET). It looks in the Automate Control Center folder
(`LabTech Client`), the Automate server folder (`LabTech`), the MySQL Connector/NET install folders and the
GAC. Pass `-MySqlDataPath` if it is somewhere else.

## EXAMPLES

### Example 1: Export everything from the database
```powershell
Import-Module .\AutomateAPI.psd1
Export-AutomateScript -Server automate-db.contoso.local -Credential (Get-Credential) -OutputPath C:\Temp\AutomateScripts
```

### Example 2: Decode scripts exported from the Control Center
```powershell
Export-AutomateScript -XmlPath C:\Temp\ExportedXml -OutputPath C:\Temp\AutomateScripts
```

### Example 3: Export two scripts and keep the decoded XML
```powershell
Export-AutomateScript -Server 10.0.0.5 -Credential $Cred -OutputPath .\Out -ScriptId 101,202 -IncludeRawXml -PassThru |
    Select-Object ScriptName, FolderPath, @{ n = 'Steps'; e = { $_.Steps.Count } }
```

## PARAMETERS

### -Server
Host name or IP of the Automate MySQL server.

### -Port
MySQL port. Default 3306.

### -Database
Automate database name. Default `labtech`.

### -Credential
MySQL user name and password. A read-only account is recommended. You are prompted if it is not given.

### -MySqlDataPath
Full path to MySql.Data.dll, if it is not found automatically.

### -ConnectionOptions
Extra MySQL connection string settings, for example `SslMode=Required`.

### -XmlPath
One or more Automate script XML exports, or folders of them (searched recursively). Scripts packed inside
an export because the main script calls them are exported too.

### -OutputPath
Folder to write to. Created if needed. Files with the same names are overwritten.

### -ScriptId
Only export these script ids.

### -IncludeRawXml
Also save each script's decoded ScriptData XML as `<Id> - <Name>.ScriptData.xml`.

### -PassThru
Also return the exported script objects.

## NOTES
Step function names, parameter names and value lists come from `Data\AutomateScriptFunctions.json`, derived
from the MIT licensed labtech-script-decode project (see `Data\THIRD-PARTY-NOTICES.md`). A step whose
function is not in that catalog is still exported with its raw parameters and is listed as a warning.

Parameters that point at other Automate records by id (users, groups, EDFs, tickets, patches and so on)
are shown as the raw id in this version. Script ids are resolved to script names.

## RELATED LINKS
