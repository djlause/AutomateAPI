function ConvertFrom-AutomateScriptBlob {
    <#
      .SYNOPSIS
        Turns a ScriptData or LicenseData value from Automate into its XML text.
      .DESCRIPTION
        Automate keeps script steps (ScriptData) and licence info (LicenseData) as gzip-compressed XML.
        In the lt_scripts table the value is usually raw gzip bytes. In Automate's XML export it is the
        same bytes encoded as base64. This function accepts either form, and also plain XML text, and
        returns the XML as a string. It returns $null for an empty value.
      .PARAMETER Value
        A byte array (from the database) or a string (base64 from an XML export, or plain XML).
      .NOTES
        Assumption: the database column holds the gzip bytes directly. If a server stores base64 text
        in the column instead, the base64 branch below handles that too.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value -or $Value -is [System.DBNull]) { return $null }

    [byte[]]$Bytes = $null
    if ($Value -is [byte[]]) {
        $Bytes = $Value
    }
    elseif ($Value -is [string]) {
        $Text = $Value.Trim()
        if ($Text -eq '') { return $null }
        if ($Text.StartsWith('<')) { return $Text }
        try {
            $Bytes = [System.Convert]::FromBase64String($Text)
        }
        catch {
            throw "Value is neither XML nor base64 text: $($_.Exception.Message)"
        }
    }
    else {
        throw "Unsupported value type $($Value.GetType().FullName)"
    }

    if ($Bytes.Length -eq 0) { return $null }

    # Gzip streams start with 0x1F 0x8B
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0x1F -and $Bytes[1] -eq 0x8B) {
        $InStream = New-Object System.IO.MemoryStream(, $Bytes)
        $Gzip = New-Object System.IO.Compression.GZipStream($InStream, [System.IO.Compression.CompressionMode]::Decompress)
        $OutStream = New-Object System.IO.MemoryStream
        try {
            $Gzip.CopyTo($OutStream)
            $Bytes = $OutStream.ToArray()
        }
        finally {
            $Gzip.Dispose(); $InStream.Dispose(); $OutStream.Dispose()
        }
    }

    $Xml = [System.Text.Encoding]::UTF8.GetString($Bytes)
    # Strip a UTF-8 byte order mark if one is present
    $Xml = $Xml.TrimStart([char]0xFEFF)

    # The column may hold base64 text stored as bytes
    if (-not $Xml.TrimStart().StartsWith('<')) {
        try {
            return ConvertFrom-AutomateScriptBlob -Value ([System.Text.Encoding]::ASCII.GetString($Bytes))
        }
        catch {
            throw "Could not decode value. It is not gzip, base64 or XML."
        }
    }
    return $Xml
}
