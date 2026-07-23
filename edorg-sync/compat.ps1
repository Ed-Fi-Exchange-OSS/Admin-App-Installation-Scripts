<#
.SYNOPSIS
    Compatibility helpers so the edorg-sync scripts run on both Windows
    PowerShell 5.1 and PowerShell 7+.

.DESCRIPTION
    Dot-sourced by the other edorg-sync scripts. On Windows PowerShell it
    aligns the native-pipe encoding with PowerShell 7, and provides
    Write-Utf8BomFile because 5.1 has no 'utf8BOM' encoding name.
#>
#requires -Version 5.1

if ($PSVersionTable.PSVersion.Major -lt 6)
{
    # Match PowerShell 7's UTF-8 encoding when piping SQL to psql / docker
    # exec (5.1 defaults to ASCII, which mangles non-ASCII names). BOM-less,
    # so no stray EF BB BF reaches the native tool's stdin.
    $OutputEncoding = New-Object System.Text.UTF8Encoding $false
}

function Write-Utf8BomFile
{
    <#
    .SYNOPSIS
        Writes a file as UTF-8 WITH a BOM on any PowerShell version.
    .DESCRIPTION
        Set-Content -Encoding utf8BOM does this on PS 6+, but 5.1 rejects the
        encoding name, so write through .NET instead. The BOM matters: it is
        how sqlcmd -i detects UTF-8 input.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $true))
}
