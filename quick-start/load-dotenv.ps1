<#
.SYNOPSIS
  Dot-sourced helper shared by run.ps1 and cleanup.ps1: parses a .env file
  into a hashtable.
#>
#requires -Version 5.1

function Read-DotEnv
{
    param([Parameter(Mandatory = $true)][string]$Path)

    $values = @{}
    # -Encoding UTF8 matters on Windows PowerShell 5.1, where the default is
    # ANSI (PS7 already defaults to UTF-8; 5.1's UTF8 decoder handles BOM-less
    # files fine).
    foreach ($line in Get-Content -Path $Path -Encoding UTF8)
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
