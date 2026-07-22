#requires -Version 7.0
<#
.SYNOPSIS
  Dot-sourced helper shared by run.ps1 and cleanup.ps1: parses a .env file
  into a hashtable.
#>

function Read-DotEnv
{
    param([Parameter(Mandatory = $true)][string]$Path)

    $values = @{}
    foreach ($line in Get-Content -Path $Path)
    {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $idx = $trimmed.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = $trimmed.Substring(0, $idx).Trim()
        $value = $trimmed.Substring($idx + 1).Trim()
        if ($value.Length -ge 2 -and
            (($value.StartsWith('"') -and $value.EndsWith('"')) -or
             ($value.StartsWith("'") -and $value.EndsWith("'"))))
        {
            # Quoted value: literal content, '#' allowed inside.
            $value = $value.Substring(1, $value.Length - 2)
        }
        else
        {
            # Unquoted value: strip a trailing inline comment.
            $hash = $value.IndexOf(' #')
            if ($hash -ge 0) { $value = $value.Substring(0, $hash).Trim() }
        }
        $values[$key] = $value
    }
    return $values
}
