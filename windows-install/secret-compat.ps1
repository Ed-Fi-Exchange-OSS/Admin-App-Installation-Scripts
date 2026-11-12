#requires -Version 5.1
<#
.SYNOPSIS
Shared secret helpers for the windows-install scripts.

.DESCRIPTION
Dot-sourced by 05-deploy-api.ps1 and install-all.ps1. It holds two things that must
not drift between those scripts:

- The sample secrets that Admin App 4.1 refuses to start with. The lists mirror
  packages/api/src/app/production-secrets.ts and db-encryption-secret.ts at the
  v4.1.0 tag; update them together with the Admin App.
- The parse of the App Pool's NODE_CONFIG, which holds the encryption key and must
  never reach a transcript.

Same pattern as sql-compat.ps1.

.EXAMPLE
. "$PSScriptRoot\secret-compat.ps1"
Assert-NotSampleSecret -Value $passwordPlain -Label 'Admin App DB login (-AppDbPassword)'
#>

# Admin App 4.1 rejects these (case-insensitive, trimmed) for the database password
# and the OIDC client secret when NODE_ENV is production.
$script:AdminAppSampleSecrets = @(
    'postgres',
    'YourStrong!Passw0rd',
    'big-secret-123',
    'adminapp-secret',
    'adminapp-dev-secret'
)

# Admin App 4.1 rejects these as DB_ENCRYPTION_SECRET_VALUE.KEY (case-insensitive).
$script:AdminAppSampleEncryptionKeys = @(
    'bbeadc2d4d15f5c9cfc2239b682cca392b233ee6979b6b9578d256aa01a7c565',
    'ef9c1dcd53175358daefcce54891e1779f9837d5ff25c74a674de3d1a749d81f',
    '4bb5c8ddaee19b8734675193868cd83511b04ee29ed7cc9aebc0dff5b3079dda'
)

function Test-AdminAppChecksProductionSecrets {
    <#
    .SYNOPSIS
        Does the Admin App checkout refuse to start with sample secrets?
    .DESCRIPTION
        Admin App 4.1 added the check; 4.0 does not have it. Both report version
        4.0.0 in package.json, so the check is detected by its source file.
    #>
    param([Parameter(Mandatory = $true)][string]$SourcePath)

    Test-Path -LiteralPath (Join-Path $SourcePath 'packages\api\src\app\production-secrets.ts') -PathType Leaf
}

function Test-IsSampleSecret {
    <#
    .SYNOPSIS
        Would Admin App 4.1 reject this value as a placeholder or a known sample?
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    $normalized = $Value.Trim().ToLowerInvariant()
    if ($normalized -match '^(<.*>|change-me)') { return $true }
    foreach ($sample in $script:AdminAppSampleSecrets) {
        if ($normalized -eq $sample.ToLowerInvariant()) { return $true }
    }
    return $false
}

function Assert-NotSampleSecret {
    <#
    .SYNOPSIS
        Throws when Admin App 4.1 would refuse to start with this value.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (Test-IsSampleSecret -Value $Value) {
        throw "The $Label is a publicly known sample value or a placeholder (such as 'change-me' or '<...>'). Admin App 4.1 refuses to start with it in production. Use a different value."
    }
}

function Test-IsSampleEncryptionKey {
    <#
    .SYNOPSIS
        Is this one of the sample encryption keys that Admin App 4.1 rejects?
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Key)

    $normalized = $Key.Trim().ToLowerInvariant()
    return [bool]($script:AdminAppSampleEncryptionKeys -contains $normalized)
}

function ConvertFrom-SecretJson {
    <#
    .SYNOPSIS
        Parses JSON that holds secrets, returning $null when it is not valid JSON.
    .DESCRIPTION
        The parse runs in a separate runspace with no host because the
        ConvertFrom-Json error quotes the JSON: Windows PowerShell 5.1 writes even a
        caught error to an active transcript (Start-Transcript or system-wide
        transcription), but a hostless runspace is not transcribed.
    #>
    param([Parameter(Mandatory = $true)][string]$JsonText)

    $shell = [powershell]::Create()
    try {
        $null = $shell.AddScript('param($text) try { $text | ConvertFrom-Json } catch { }').AddArgument($JsonText)
        $parsed = @($shell.Invoke())
        if ($parsed.Count -eq 0) { return $null }
        return $parsed[0]
    } finally {
        $shell.Dispose()
    }
}

function New-RandomSecretBytes {
    <#
    .SYNOPSIS
        Returns Count cryptographically random bytes.
    #>
    param([Parameter(Mandatory = $true)][int]$Count)

    $bytes = [byte[]]::new($Count)
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    } finally {
        $generator.Dispose()
    }
    return , $bytes
}
