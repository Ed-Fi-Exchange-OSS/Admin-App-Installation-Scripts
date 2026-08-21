<#
.SYNOPSIS
    Compatibility helpers so the quick-start scripts run on both Windows
    PowerShell 5.1 and PowerShell 7+.

.DESCRIPTION
    Dot-sourced by the other quick-start scripts. Provides:
      - $script:webCmdletsSupportSkipCertCheck: whether this PowerShell's web
        cmdlets accept -SkipCertificateCheck (PowerShell 6+).
      - Enable-TrustAllCertificates: the Windows PowerShell 5.1 fallback for
        -SkipCertificateCheck.
      - Get-HttpErrorBody: engine-agnostic read of a failed web request's
        response body.
      - Read-Secret: masked interactive prompt for passwords not provided in
        the .env or as parameters.
    On Windows PowerShell it also aligns TLS and pipe-encoding behavior with
    PowerShell 7 (see inline comments).
#>
#requires -Version 5.1

# Whether this PowerShell's web cmdlets support -SkipCertificateCheck (PS 6+).
# Same capability-probe pattern as the AllowInsecureRedirect check in
# quick-start.ps1.
$script:webCmdletsSupportSkipCertCheck =
    (Get-Command Invoke-RestMethod).Parameters.ContainsKey('SkipCertificateCheck')

if ($PSVersionTable.PSVersion.Major -lt 6)
{
    # Windows PowerShell only. If an explicit protocol list is configured
    # without TLS 1.2, add it. SystemDefault (the modern default) is left
    # alone -- the OS already negotiates TLS 1.2+ there, and overwriting it
    # would drop TLS 1.3.
    $current = [Net.ServicePointManager]::SecurityProtocol
    if ($current -ne [Net.SecurityProtocolType]::SystemDefault -and
        -not ($current -band [Net.SecurityProtocolType]::Tls12))
    {
        [Net.ServicePointManager]::SecurityProtocol = $current -bor [Net.SecurityProtocolType]::Tls12
    }

    # Match PowerShell 7's UTF-8 encoding when piping SQL to psql / docker
    # exec (5.1 defaults to ASCII, which mangles non-ASCII names). BOM-less,
    # so no stray EF BB BF reaches the native tool's stdin.
    $OutputEncoding = New-Object System.Text.UTF8Encoding $false
}

function Enable-TrustAllCertificates
{
    <#
    .SYNOPSIS
        Windows PowerShell 5.1 fallback for -SkipCertificateCheck.
    .DESCRIPTION
        Installs a process-wide certificate-validation override (unlike the
        per-call -SkipCertificateCheck switch on PS 6+, but consistent with the
        .env's global SKIP_CERTIFICATE_CHECK semantics, and acceptable for
        these short-lived script invocations). A compiled delegate is used
        instead of a PowerShell scriptblock, which can deadlock 5.1 when the
        callback fires on a threadpool thread.
    #>
    if (-not ('EdFiQuickStart.CertPolicy' -as [type]))
    {
        Add-Type -TypeDefinition @"
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

namespace EdFiQuickStart
{
    public static class CertPolicy
    {
        public static void TrustAll()
        {
            ServicePointManager.ServerCertificateValidationCallback =
                delegate (object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) { return true; };
        }
    }
}
"@
    }
    [EdFiQuickStart.CertPolicy]::TrustAll()
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
        values to the child scripts and native DB tools.
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

function Invoke-WithDbPassword
{
    <#
    .SYNOPSIS
        Runs a scriptblock with a database password in an environment variable,
        then puts back whatever the variable held before.
    .DESCRIPTION
        Keeps the secret off the command line. A password passed as `sqlcmd -P`
        or as `docker exec -e VAR=value` is visible to anyone who can list
        processes, for as long as the call runs; both tools read the value from
        the environment instead, which is not. This is how the edorg-sync
        scripts have always passed theirs.

        The variable is RESTORED, not deleted: a parent automation process may
        have exported its own SQLCMDPASSWORD or PGPASSWORD, and clearing it
        would break the rest of that parent's run. When the variable did not
        exist beforehand it is removed, so nothing is left behind either.

        -WhatIf:$false / -Confirm:$false on the two item calls is load-bearing:
        a caller declaring [CmdletBinding(SupportsShouldProcess)] would
        otherwise turn setting the variable into a prompt, or skip it under
        -WhatIf and run the query with no password at all.
    .EXAMPLE
        Invoke-WithDbPassword -Name SQLCMDPASSWORD -Password $pw -Action {
            & sqlcmd -S $server -U $user @trustArgs -Q $sql
        }
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('SQLCMDPASSWORD', 'PGPASSWORD')][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Password,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    $path = "Env:$Name"
    $had = Test-Path $path
    $previous = if ($had) { (Get-Item $path).Value } else { $null }
    Set-Item -Path $path -Value $Password -WhatIf:$false -Confirm:$false
    try
    {
        & $Action
    }
    finally
    {
        if ($had) { Set-Item -Path $path -Value $previous -WhatIf:$false -Confirm:$false }
        else { Remove-Item -Path $path -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false }
    }
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
        in edorg-sync\compat.ps1.
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

        This is the database counterpart of the .env's SKIP_CERTIFICATE_CHECK
        (which covers the web calls only) and is deliberately a separate knob.

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

function Get-HttpErrorBody
{
    <#
    .SYNOPSIS
        Returns the HTTP response body of a failed web-cmdlet call, or $null.
    .DESCRIPTION
        PowerShell 7 populates $_.ErrorDetails.Message; on Windows PowerShell
        5.1 that is not always set, so fall back to reading the WebException's
        response stream.
    #>
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message)
    {
        return $ErrorRecord.ErrorDetails.Message
    }
    $response = $ErrorRecord.Exception.Response
    if ($response -is [System.Net.HttpWebResponse])
    {
        try
        {
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
            $body = $reader.ReadToEnd()
            $reader.Dispose()
            if ($body) { return $body }
        }
        catch { }
    }
    return $null
}
