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
