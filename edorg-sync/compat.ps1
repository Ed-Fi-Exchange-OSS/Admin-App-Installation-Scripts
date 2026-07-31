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

function Read-Secret
{
    <#
    .SYNOPSIS
        Masked interactive prompt for a secret; returns the plaintext value.
    .DESCRIPTION
        Used when a password is not provided in the .env or as a parameter.
        SecureString -> plaintext the 5.1-compatible way (ConvertFrom-
        SecureString -AsPlainText is PS7+); the scripts pass plain [string]
        values to the native DB tools.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Prompt
    )
    $secure = Read-Host -Prompt "$Prompt [$Name]" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if (-not $value) { throw "No value entered for $Name. Set it in the .env (or pass the parameter) or enter it at the prompt." }
    return $value
}

function Get-SqlcmdTrustArgs
{
    <#
    .SYNOPSIS
        Returns the sqlcmd arguments controlling server-certificate trust.
    .DESCRIPTION
        The sqlcmd shipped with SQL Server 2025 enforces an encrypted
        connection by default AND validates the server certificate, which the
        auto-generated self-signed certificate of a local instance fails
        ("the certificate chain was issued by an authority that is not
        trusted"). -C (trust server certificate) clears that, but it disables
        validation, so it is emitted only where that is safe by construction:
          - the target is loopback -- a local instance, where there is no
            machine-in-the-middle surface to protect against; or
          - the operator explicitly opted in with -TrustServerCertificate.
        A remote host without the opt-in keeps validating, so the SQL login
        password is never presented to a forged endpoint.

        Callers must wrap the result in @(...) before splatting: assigning a
        one-element array unrolls it to a scalar string, and splatting a
        scalar to a native command garbles the argument list.
    #>
    param(
        [string]$SqlServer,
        [switch]$TrustServerCertificate
    )

    if ($TrustServerCertificate) { return @('-C') }
    # No -S at all means sqlcmd's default: the local default instance.
    if ([string]::IsNullOrWhiteSpace($SqlServer)) { return @('-C') }

    # Local named pipes (\\.\pipe\...) are loopback by definition, and would
    # otherwise normalize to an empty host below.
    $value = $SqlServer.Trim()
    if ($value -match '^(np:)?\\\\(\.|localhost|127\.0\.0\.1)\\') { return @('-C') }

    # Drop the protocol prefix, then keep the host portion only (everything
    # before a ,port or \instance suffix). '(local)' loses its parentheses.
    $target = ($value -replace '^(tcp|np|lpc|admin):', '') -split '[,\\]' | Select-Object -First 1
    $target = $target.Trim().Trim('(', ')')

    # -in is case-insensitive, which matters for the machine name.
    $loopback = @('local', 'localhost', '.', '127.0.0.1', '::1', '[::1]')
    if ($env:COMPUTERNAME) { $loopback += $env:COMPUTERNAME }
    if ($target -in $loopback) { return @('-C') }

    return @()
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
