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

function Test-IsRemoteSqlTarget
{
    <#
    .SYNOPSIS
        Is the SQL target a remote server rather than the local instance?
    .DESCRIPTION
        A remote target such as a managed Azure SQL Database changes two
        decisions: how sqlcmd secures the connection (see
        Get-SqlcmdTrustArgs) and whether Windows integrated authentication is
        usable at all (it is not, on Azure SQL). Both read this one predicate
        so they cannot disagree about what "remote" means.

        Normalization: drop the protocol prefix, keep the host portion
        (everything before a ,port or \instance suffix), and compare against
        the loopback forms plus this machine's own name. Matches
        Test-IsRemoteSqlTarget in windows-install\sql-compat.ps1 and the copy
        in quick-start\compat.ps1.
    #>
    param([string]$SqlServer)

    # No -S at all means sqlcmd's default: the local default instance.
    if ([string]::IsNullOrWhiteSpace($SqlServer)) { return $false }

    # Local named pipes (\\.\pipe\...) are loopback by definition, and would
    # otherwise normalize to an empty host below.
    $value = $SqlServer.Trim()
    if ($value -match '^(np:)?\\\\(\.|localhost|127\.0\.0\.1)\\') { return $false }

    # Drop the protocol prefix, then keep the host portion only (everything
    # before a ,port or \instance suffix). '(local)' loses its parentheses.
    $target = ($value -replace '^(tcp|np|lpc|admin):', '') -split '[,\\]' | Select-Object -First 1
    $target = $target.Trim().Trim('(', ')')

    # -notin is case-insensitive, which matters for the machine name.
    $loopback = @('local', 'localhost', '.', '127.0.0.1', '::1', '[::1]')
    if ($env:COMPUTERNAME) { $loopback += $env:COMPUTERNAME }
    return ($target -notin $loopback)
}

function Get-SqlcmdTrustArgs
{
    <#
    .SYNOPSIS
        Returns the sqlcmd arguments controlling connection encryption and
        server-certificate validation.
    .DESCRIPTION
        -N requests an encrypted connection; -C trusts the server certificate
        without validating it. Omitting BOTH does not mean "validate": per the
        sqlcmd documentation, "if you don't provide -N and -C, sqlcmd
        negotiates authentication with the server without validating the
        server certificate", so a remote target must pass -N explicitly to get
        validation. Measured with sqlcmd 16.0.1000.6 (ODBC Driver 17) against
        an instance holding an untrusted self-signed certificate: no flags
        connects (exit 0, unvalidated), -N alone fails with "The certificate
        chain was issued by an authority that is not trusted", and -N -C
        connects.

        By target:
          - local instance (or a blank host, which is sqlcmd's local default):
            -C. The auto-generated self-signed certificate of a local instance
            fails validation, and there is no machine-in-the-middle surface on
            loopback. -C is also what the sqlcmd shipped with SQL Server 2025
            needs, since it encrypts and validates by default.
          - remote: -N, so the connection is encrypted AND the certificate
            validated, and the SQL login password is never presented to a
            forged endpoint.
          - remote with -TrustServerCertificate: -N -C, the operator's
            explicit opt out of validation for a server presenting a
            self-signed/dev certificate.

        The bare -N switch is deliberate. sqlcmd 18 and later accept an
        optional value (-N[s|m|o], bare -N meaning mandatory), but sqlcmd 17
        and earlier reject one ("'m': Unexpected argument"), so only the bare
        form works across the versions these scripts support.

        Callers must wrap the result in @(...) before splatting: assigning a
        one-element array unrolls it to a scalar string, and splatting a
        scalar to a native command garbles the argument list.
    #>
    param(
        [string]$SqlServer,
        [switch]$TrustServerCertificate
    )

    if (-not (Test-IsRemoteSqlTarget -SqlServer $SqlServer)) { return @('-C') }
    if ($TrustServerCertificate) { return @('-N', '-C') }
    return @('-N')
}

function Assert-SqlAuthSupported
{
    <#
    .SYNOPSIS
        Throws when Windows integrated authentication is requested against a
        remote SQL target.
    .DESCRIPTION
        A managed Azure SQL Database does not accept sqlcmd -E: the failure
        surfaces as a raw driver error ("Cannot open server ... requested by
        the login" or an SSPI handshake failure) well after the script has
        prompted for other values. Fail up front instead, naming the target
        and the parameters that do work. A domain-joined remote SQL Server
        does accept -E, but these scripts cannot distinguish it from Azure SQL
        by name alone, so the safe default is to refuse and let the operator
        pass a SQL login.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SqlServer,
        [Parameter(Mandatory = $true)][bool]$UseIntegratedSecurity,
        [Parameter(Mandatory = $true)][string]$UsernameParameterName,
        [Parameter(Mandatory = $true)][string]$PasswordParameterName
    )

    if (-not $UseIntegratedSecurity) { return }
    if (-not (Test-IsRemoteSqlTarget -SqlServer $SqlServer)) { return }

    throw "Windows integrated authentication (-UseIntegratedSecurity / sqlcmd -E) is not supported against the remote SQL target '$SqlServer'. A managed Azure SQL Database accepts SQL authentication only: drop the switch and pass $UsernameParameterName / $PasswordParameterName instead."
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
