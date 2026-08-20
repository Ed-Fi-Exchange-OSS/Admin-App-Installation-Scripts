#requires -Version 5.1
<#
.SYNOPSIS
Shared SQL-target helpers for the windows-install scripts.

.DESCRIPTION
Dot-sourced by 00-check-prereqs.ps1, 02-prereqs-sql.ps1, 05-deploy-api.ps1,
install-all.ps1 and uninstall.ps1 so that "is this target local or remote?" and
"how does sqlcmd secure the connection?" are answered in exactly one place: both
decisions change together whenever the supported target formats or the encryption
behaviour change, and a copy that drifts silently weakens the remote path.

Same pattern as quick-start/compat.ps1 and edorg-sync/compat.ps1, which those
folders dot-source for their own shared helpers.

.EXAMPLE
. "$PSScriptRoot\sql-compat.ps1"
$isRemote = Test-IsRemoteSqlTarget -SqlServerHost $SqlServerHost
$sqlSecurityArgs = Get-SqlcmdSecurityArgs -SqlServerHost $SqlServerHost -TrustServerCertificate:$TrustServerCertificate
& sqlcmd -S "tcp:$SqlServerHost,$SqlServerPort" -U $AppDbUsername @sqlSecurityArgs -Q "SELECT 1"
#>

function Test-IsRemoteSqlTarget {
    <#
    .SYNOPSIS
        Is the SQL target a remote server rather than the local instance?
    .DESCRIPTION
        A local (loopback) target gets Windows Authentication, the registry/service
        setup, and a database created by the installer. A remote target such as a
        managed Azure SQL Database gets none of those: it is provisioned as a SQL
        admin against a database the operator created.

        Normalization matches Get-SqlcmdTrustArgs in quick-start/compat.ps1 and
        edorg-sync/compat.ps1: drop the protocol prefix, keep the host portion
        (everything before a ,port or \instance suffix), and compare against the
        loopback forms plus this machine's own name.
    #>
    param([string]$SqlServerHost)

    if ([string]::IsNullOrWhiteSpace($SqlServerHost)) { return $false }
    $value = $SqlServerHost.Trim()
    # Local named pipes (\\.\pipe\..., optionally np:-prefixed) are loopback by
    # definition and would otherwise normalize to an empty host below.
    if ($value -match '^(np:)?\\\\(\.|localhost|127\.0\.0\.1)\\') { return $false }
    $target = ($value -replace '^(tcp|np|lpc|admin):', '') -split '[,\\]' | Select-Object -First 1
    $target = $target.Trim().Trim('(', ')')
    # -notin is case-insensitive, which matters for the machine name.
    $loopback = @('local', 'localhost', '.', '127.0.0.1', '::1', '[::1]')
    if ($env:COMPUTERNAME) { $loopback += $env:COMPUTERNAME }
    return ($target -notin $loopback)
}

function Get-SqlcmdSecurityArgs {
    <#
    .SYNOPSIS
        Returns the sqlcmd arguments controlling connection encryption and
        server-certificate validation for a target.
    .DESCRIPTION
        -N requests an encrypted connection; -C trusts the server certificate
        without validating it. Omitting BOTH does not mean "validate": per the
        sqlcmd documentation, "if you don't provide -N and -C, sqlcmd negotiates
        authentication with the server without validating the server certificate",
        so a remote target must pass -N explicitly to get validation. Measured with
        sqlcmd 16.0.1000.6 (ODBC Driver 17) against a local instance holding an
        untrusted self-signed certificate: no flags connects (exit 0, unvalidated),
        -N alone fails with "The certificate chain was issued by an authority that
        is not trusted", and -N -C connects.

        By target:
        - local instance (or a blank host, which is sqlcmd's local default): -C.
          The auto-generated self-signed certificate of a local instance fails
          validation, and there is no machine-in-the-middle surface on loopback.
          -C is also what the sqlcmd shipped with SQL Server 2025 needs, since it
          encrypts and validates by default.
        - remote: -N, so the connection is encrypted AND the certificate validated,
          and the SQL login password is never presented to a forged endpoint.
        - remote with -TrustServerCertificate: -N -C, the operator's explicit opt
          out of validation for a server presenting a self-signed/dev certificate.

        The bare -N switch is deliberate. sqlcmd 18 and later accept an optional
        value (-N[s|m|o], bare -N meaning mandatory), but sqlcmd 17 and earlier
        reject one ("'m': Unexpected argument"), so only the bare form works across
        the versions these scripts support -- all of which ship with SQL Server or
        the ODBC command-line tools. (The separate Go build of sqlcmd takes -N as a
        string value and would need -N true instead.)

        Callers must wrap the result in @(...) before splatting, exactly as with
        Get-SqlcmdTrustArgs in quick-start/compat.ps1 and edorg-sync/compat.ps1:
        returning a one-element array unrolls it to a scalar string, and splatting a
        string to a native command iterates its characters, so sqlcmd would see a
        bogus '-' option instead of '-C'.
    #>
    param(
        [string]$SqlServerHost,
        [switch]$TrustServerCertificate
    )

    if (-not (Test-IsRemoteSqlTarget -SqlServerHost $SqlServerHost)) { return @('-C') }
    if ($TrustServerCertificate) { return @('-N', '-C') }
    return @('-N')
}

function Test-DbPasswordNotUsername {
    <#
    .SYNOPSIS
        Throws when a database password contains the login name (remote targets).
    .DESCRIPTION
        A managed Azure SQL target rejects a database password that contains the
        login name -- or any 3+ character alphanumeric part of it -- failing
        CREATE USER with an opaque "Msg 40632 ... not complex enough". Local SQL
        Server's CHECK_POLICY does not enforce this, so callers apply it only for a
        remote target, which keeps example passwords such as 'EdFi-App-Local!2026'
        valid on a local instance.

        Split the username on non-alphanumeric delimiters -- the Windows/Azure
        tokenization -- and reject the password if it contains the whole name or any
        such token, case-insensitive.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Password,
        [Parameter(Mandatory = $true)][string]$Username
    )

    foreach ($token in @($Username) + ($Username -split '[^A-Za-z0-9]+')) {
        if ($token.Length -ge 3 -and $Password -match [regex]::Escape($token)) {
            throw "The Admin App DB password must not contain the login name or a part of it ('$token'): a managed Azure SQL target rejects such a password (Msg 40632, 'not complex enough'). Choose a password with no 3+ character part of the username '$Username'."
        }
    }
}
