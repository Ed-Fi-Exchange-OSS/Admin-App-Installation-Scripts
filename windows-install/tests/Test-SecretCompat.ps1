#requires -Version 5.1
<#
.SYNOPSIS
Tests the shared secret helpers in windows-install\secret-compat.ps1.

.DESCRIPTION
Covers the sample secrets that Admin App 4.1 refuses to start with (database
password, OIDC client secret, encryption key), the detection of a checkout that has
that check, the transcript-safe NODE_CONFIG parse, and the random-bytes helper.
These run without IIS, a database or any module: plain PowerShell, so they work on
both Windows PowerShell 5.1 and PowerShell 7.

Exits 0 when every test passes and 1 when any test fails.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SecretCompat.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SecretCompat.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\secret-compat.ps1"

$script:Passed = 0
$script:Failed = 0

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Expected,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Actual,
        [Parameter(Mandatory = $true)][string]$Because
    )
    if ($Expected -ceq $Actual) {
        $script:Passed++
        Write-Host "  PASS  $Because" -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host "  FAIL  $Because -- expected '$Expected', got '$Actual'" -ForegroundColor Red
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Because
    )
    try {
        & $Action
        $script:Failed++
        Write-Host "  FAIL  $Because -- no error was thrown" -ForegroundColor Red
    } catch {
        $script:Passed++
        Write-Host "  PASS  $Because" -ForegroundColor Green
    }
}

function Assert-DoesNotThrow {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Because
    )
    try {
        & $Action
        $script:Passed++
        Write-Host "  PASS  $Because" -ForegroundColor Green
    } catch {
        $script:Failed++
        Write-Host "  FAIL  $Because -- threw: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Test-IsSampleSecret -- the values Admin App 4.1 refuses" -ForegroundColor Cyan
foreach ($sample in @('postgres', 'YourStrong!Passw0rd', 'big-secret-123', 'adminapp-secret', 'adminapp-dev-secret')) {
    Assert-Equal -Expected 'True' -Actual "$(Test-IsSampleSecret -Value $sample)" -Because "'$sample' is a known sample"
}
Assert-Equal -Expected 'True' -Actual "$(Test-IsSampleSecret -Value 'yourstrong!passw0rd')" -Because 'the comparison ignores case'
Assert-Equal -Expected 'True' -Actual "$(Test-IsSampleSecret -Value '  big-secret-123  ')" -Because 'surrounding white space is trimmed'
Assert-Equal -Expected 'True' -Actual "$(Test-IsSampleSecret -Value 'change-me')" -Because "'change-me' is a placeholder"
Assert-Equal -Expected 'True' -Actual "$(Test-IsSampleSecret -Value 'Change-Me-Please')" -Because "a value that starts with 'change-me' is a placeholder"
Assert-Equal -Expected 'True' -Actual "$(Test-IsSampleSecret -Value '<your-password>')" -Because "a '<...>' value is a placeholder"
Assert-Equal -Expected 'False' -Actual "$(Test-IsSampleSecret -Value 'EdFi-App-Local!2026')" -Because 'a real password is accepted'
Assert-Equal -Expected 'False' -Actual "$(Test-IsSampleSecret -Value 'postgres-2026!X')" -Because 'a value that only contains a sample is accepted, as in 4.1'
Assert-Equal -Expected 'False' -Actual "$(Test-IsSampleSecret -Value 'please-change-me')" -Because "'change-me' counts only at the start, as in 4.1"

Write-Host ""
Write-Host "Assert-NotSampleSecret -- the message names the parameter" -ForegroundColor Cyan
Assert-Throws -Because 'a sample value throws' -Action { Assert-NotSampleSecret -Value 'big-secret-123' -Label 'OIDC client secret (-OidcClientSecret)' }
Assert-DoesNotThrow -Because 'a real value does not throw' -Action { Assert-NotSampleSecret -Value 'Kc-Client!9x2' -Label 'OIDC client secret (-OidcClientSecret)' }
try {
    Assert-NotSampleSecret -Value 'postgres' -Label 'Postgres app user password (-PostgresAppPassword)'
    $message = ''
} catch {
    $message = $_.Exception.Message
}
Assert-Equal -Expected 'True' -Actual "$($message.Contains('-PostgresAppPassword'))" -Because 'the error names the parameter to change'
Assert-Equal -Expected 'False' -Actual "$($message.Contains('postgres''') -or $message.Contains(' postgres '))" -Because 'the error does not echo the rejected value'

Write-Host ""
Write-Host "Test-IsSampleEncryptionKey -- the three keys Admin App 4.1 refuses" -ForegroundColor Cyan
foreach ($key in @(
        'bbeadc2d4d15f5c9cfc2239b682cca392b233ee6979b6b9578d256aa01a7c565',
        'ef9c1dcd53175358daefcce54891e1779f9837d5ff25c74a674de3d1a749d81f',
        '4bb5c8ddaee19b8734675193868cd83511b04ee29ed7cc9aebc0dff5b3079dda')) {
    Assert-Equal -Expected 'True' -Actual "$(Test-IsSampleEncryptionKey -Key $key)" -Because "sample key $($key.Substring(0, 8))... is refused"
}
Assert-Equal -Expected 'True' -Actual "$(Test-IsSampleEncryptionKey -Key 'BBEADC2D4D15F5C9CFC2239B682CCA392B233EE6979B6B9578D256AA01A7C565')" -Because 'the comparison ignores case'
Assert-Equal -Expected 'False' -Actual "$(Test-IsSampleEncryptionKey -Key ('0123456789abcdef' * 4))" -Because 'another key is accepted'
Assert-Equal -Expected 'False' -Actual "$(Test-IsSampleEncryptionKey -Key '')" -Because 'an empty key is not a sample key'

Write-Host ""
Write-Host "Test-AdminAppChecksProductionSecrets -- detected by the 4.1 source file" -ForegroundColor Cyan
$checkout = Join-Path ([System.IO.Path]::GetTempPath()) ("secret-compat-" + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $checkout | Out-Null
    Assert-Equal -Expected 'False' -Actual "$(Test-AdminAppChecksProductionSecrets -SourcePath $checkout)" -Because 'a 4.0 checkout has no check'
    $appFolder = Join-Path $checkout 'packages\api\src\app'
    New-Item -ItemType Directory -Path $appFolder -Force | Out-Null
    Set-Content -Path (Join-Path $appFolder 'production-secrets.ts') -Value '// stub'
    Assert-Equal -Expected 'True' -Actual "$(Test-AdminAppChecksProductionSecrets -SourcePath $checkout)" -Because 'a 4.1 checkout has the check'
} finally {
    Remove-Item -LiteralPath $checkout -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "ConvertFrom-SecretJson -- parses, and fails quietly" -ForegroundColor Cyan
$parsed = ConvertFrom-SecretJson -JsonText '{"DB_ENCRYPTION_SECRET_VALUE":{"KEY":"abc"},"SESSION_SECRET_VALUE":["s1","s2"]}'
Assert-Equal -Expected 'abc' -Actual "$($parsed.DB_ENCRYPTION_SECRET_VALUE.KEY)" -Because 'a nested value is read'
Assert-Equal -Expected '2' -Actual "$(@($parsed.SESSION_SECRET_VALUE).Count)" -Because 'an array keeps its entries'
$single = ConvertFrom-SecretJson -JsonText '{"SESSION_SECRET_VALUE":"only-one"}'
Assert-Equal -Expected 'only-one' -Actual "$(@($single.SESSION_SECRET_VALUE)[0])" -Because 'a single string value is read'
Assert-Equal -Expected '' -Actual "$(ConvertFrom-SecretJson -JsonText '{"KEY": "secret-value"')" -Because 'invalid JSON returns nothing instead of throwing'
$errorsBefore = $Error.Count
$null = ConvertFrom-SecretJson -JsonText '{not json, secret-value'
Assert-Equal -Expected "$errorsBefore" -Actual "$($Error.Count)" -Because 'the parse error is not recorded in this session, where a transcript would see it'

Write-Host ""
Write-Host "New-RandomSecretBytes -- length and randomness" -ForegroundColor Cyan
$first = New-RandomSecretBytes -Count 32
$second = New-RandomSecretBytes -Count 32
Assert-Equal -Expected 'System.Byte[]' -Actual $first.GetType().FullName -Because 'the result is a byte array, not an unrolled list'
Assert-Equal -Expected '32' -Actual "$($first.Length)" -Because 'the requested number of bytes is returned'
Assert-Equal -Expected 'False' -Actual "$([Convert]::ToBase64String($first) -eq [Convert]::ToBase64String($second))" -Because 'two calls return different bytes'

Write-Host ""
Write-Host ("{0} passed, {1} failed." -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed) { 'Red' } else { 'Green' })
if ($script:Failed) { exit 1 }
exit 0
