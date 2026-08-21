#requires -Version 5.1
<#
.SYNOPSIS
Tests the shared SQL-target helpers in quick-start\compat.ps1.

.DESCRIPTION
Covers the decisions that switch the Quick Start scripts between a local SQL Server
instance and a remote target such as a managed Azure SQL Database: remote-target
detection across the host formats sqlcmd accepts, the sqlcmd encryption/certificate
flags per target, that those flags survive splatting to a native command, and the
refusal of Windows integrated authentication against a remote target. These run
without a database, a server, or any module: plain PowerShell, so they work on both
Windows PowerShell 5.1 and PowerShell 7.

Mirrors windows-install\tests\Test-SqlCompat.ps1, which covers the same helpers for
the installer. The two copies must agree: an operator who points install-all.ps1 and
the Quick Start at the same server expects both to secure the connection the same
way.

Exits 0 when every test passes and 1 on the first failure count, so it can gate a
change from a command line or a future CI step.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SqlCompat.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SqlCompat.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/../compat.ps1"

$script:Passed = 0
$script:Failed = 0

function Assert-Equal
{
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Expected,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Actual,
        [Parameter(Mandatory = $true)][string]$Because
    )
    if ($Expected -ceq $Actual)
    {
        $script:Passed++
        Write-Host "  PASS  $Because" -ForegroundColor Green
    }
    else
    {
        $script:Failed++
        Write-Host "  FAIL  $Because -- expected '$Expected', got '$Actual'" -ForegroundColor Red
    }
}

function Assert-Throws
{
    <#
        -Matching asserts what the message SAYS, not merely that something was
        thrown. Without it a refusal that stopped naming the target, or stopped
        telling the operator which parameters to use instead, would still pass
        and the actionable wording could rot unnoticed.
    #>
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Because,
        [string[]]$Matching
    )
    $message = $null
    try
    {
        & $Action
    }
    catch
    {
        $message = "$($_.Exception.Message)"
    }
    if ($null -eq $message)
    {
        $script:Failed++
        Write-Host "  FAIL  $Because -- no error was thrown" -ForegroundColor Red
        return
    }
    $absent = @($Matching | Where-Object { $_ -and $message -notlike "*$_*" })
    if ($absent.Count -gt 0)
    {
        $script:Failed++
        Write-Host "  FAIL  $Because -- the message never mentioned '$($absent -join "', '")': $message" -ForegroundColor Red
        return
    }
    $script:Passed++
    Write-Host "  PASS  $Because" -ForegroundColor Green
}

function Assert-DoesNotThrow
{
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Because
    )
    try
    {
        & $Action
        $script:Passed++
        Write-Host "  PASS  $Because" -ForegroundColor Green
    }
    catch
    {
        $script:Failed++
        Write-Host "  FAIL  $Because -- threw: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Echoes back whatever it is splatted -- token count included, since one argument
# reading '-N -C' and two arguments reading '-N' and '-C' are indistinguishable once
# joined. Stands in for sqlcmd so a test can assert what a native command receives.
function Get-SplattedArgs
{
    return "count=$($args.Count) :: " + ($args -join ' ')
}

Write-Host ""
Write-Host "Test-IsRemoteSqlTarget -- local targets" -ForegroundColor Cyan
foreach ($local in @('localhost', 'LOCALHOST', '(local)', '.', '127.0.0.1', '::1', '[::1]',
                     'tcp:localhost,1433', 'tcp:127.0.0.1,1433', 'localhost\SQLEXPRESS',
                     'np:\\.\pipe\sql\query', '\\localhost\pipe\sql\query', '', '   ',
                     $env:COMPUTERNAME, "tcp:$env:COMPUTERNAME,1433"))
{
    Assert-Equal -Expected 'False' -Actual "$(Test-IsRemoteSqlTarget -SqlServer $local)" -Because "'$local' is local"
}

Write-Host ""
Write-Host "Test-IsRemoteSqlTarget -- remote targets" -ForegroundColor Cyan
foreach ($remote in @('myserver.database.windows.net', 'tcp:myserver.database.windows.net,1433',
                      'MYSERVER.DATABASE.WINDOWS.NET', '10.0.0.5', 'tcp:10.0.0.5,1433',
                      'sqlbox', 'sqlbox\SQLEXPRESS'))
{
    Assert-Equal -Expected 'True' -Actual "$(Test-IsRemoteSqlTarget -SqlServer $remote)" -Because "'$remote' is remote"
}

Write-Host ""
Write-Host "Get-SqlcmdTrustArgs -- flags per target" -ForegroundColor Cyan
# A local instance presents an auto-generated self-signed certificate: trust it
# (-C) instead of failing validation. No machine-in-the-middle surface on loopback.
Assert-Equal -Expected '-C' -Actual ((Get-SqlcmdTrustArgs -SqlServer 'localhost') -join ' ') -Because 'local target trusts the certificate'
Assert-Equal -Expected '-C' -Actual ((Get-SqlcmdTrustArgs -SqlServer '') -join ' ') -Because "no host (sqlcmd's local default) trusts the certificate"
Assert-Equal -Expected '-C' -Actual ((Get-SqlcmdTrustArgs -SqlServer 'localhost' -TrustServerCertificate) -join ' ') -Because 'local target with the opt-in still just trusts'
# The remote cases are the security-relevant ones: -N is what makes sqlcmd validate
# the certificate. Omitting both -N and -C encrypts without validating, which is what
# this helper returned before EDFI-2895.
Assert-Equal -Expected '-N' -Actual ((Get-SqlcmdTrustArgs -SqlServer 'myserver.database.windows.net') -join ' ') -Because 'remote target encrypts and validates'
Assert-Equal -Expected '-N -C' -Actual ((Get-SqlcmdTrustArgs -SqlServer 'myserver.database.windows.net' -TrustServerCertificate) -join ' ') -Because 'remote target with the opt-in encrypts and trusts'
Assert-Equal -Expected '-N' -Actual ((Get-SqlcmdTrustArgs -SqlServer 'tcp:myserver.database.windows.net,1433') -join ' ') -Because 'a protocol-prefixed remote host still validates'

Write-Host ""
Write-Host "Get-SqlcmdTrustArgs -- the result splats as separate arguments" -ForegroundColor Cyan
# These assert the CALL-SITE expression the scripts use, `@(Get-...)`, not just the
# return value: two array traps sit between the function and sqlcmd. A one-element
# array unrolls to a bare string, and splatting a string iterates its characters, so
# sqlcmd would receive '-' and 'C' as two bogus options; a doubly wrapped array
# collapses the other way, splatting '-N -C' as ONE token that sqlcmd cannot parse.
# Assert the token COUNT as well as the text -- '-N -C' as one argument and as two
# look identical once joined.
$localArgs = @(Get-SqlcmdTrustArgs -SqlServer 'localhost')
Assert-Equal -Expected '1' -Actual "$($localArgs.Count)" -Because 'the local flag list holds one element'
Assert-Equal -Expected 'count=1 :: -C' -Actual (Get-SplattedArgs @localArgs) -Because 'the local flag splats as one token'
$remoteArgs = @(Get-SqlcmdTrustArgs -SqlServer 'myserver.database.windows.net')
Assert-Equal -Expected '1' -Actual "$($remoteArgs.Count)" -Because 'the remote flag list holds one element'
Assert-Equal -Expected 'count=1 :: -N' -Actual (Get-SplattedArgs @remoteArgs) -Because 'the remote flag splats as one token'
$remoteTrustArgs = @(Get-SqlcmdTrustArgs -SqlServer 'myserver.database.windows.net' -TrustServerCertificate)
Assert-Equal -Expected '2' -Actual "$($remoteTrustArgs.Count)" -Because 'the remote opt-out flag list holds two elements'
Assert-Equal -Expected 'count=2 :: -N -C' -Actual (Get-SplattedArgs @remoteTrustArgs) -Because 'both remote flags splat as two separate tokens'

Write-Host ""
Write-Host "Assert-SqlAuthSupported -- Windows authentication against a remote target" -ForegroundColor Cyan
Assert-Throws -Because 'integrated security is refused for a remote host, naming the target and the way out' `
    -Matching 'myserver.database.windows.net', '-UseIntegratedSecurity', '-SecurityDbUsername', '-SecurityDbPassword', 'SQL authentication' -Action {
    Assert-SqlAuthSupported -SqlServer 'myserver.database.windows.net' -UseIntegratedSecurity $true -UsernameParameterName '-SecurityDbUsername' -PasswordParameterName '-SecurityDbPassword'
}
Assert-DoesNotThrow -Because 'integrated security is allowed for a local instance' -Action {
    Assert-SqlAuthSupported -SqlServer 'tcp:localhost,1433' -UseIntegratedSecurity $true -UsernameParameterName '-SecurityDbUsername' -PasswordParameterName '-SecurityDbPassword'
}
Assert-DoesNotThrow -Because 'a remote host with SQL authentication is allowed' -Action {
    Assert-SqlAuthSupported -SqlServer 'myserver.database.windows.net' -UseIntegratedSecurity $false -UsernameParameterName '-SecurityDbUsername' -PasswordParameterName '-SecurityDbPassword'
}

Write-Host ""
Write-Host "Invoke-WithDbPassword -- the variable is restored, never just cleared" -ForegroundColor Cyan
# The point of the helper: a parent automation process may have exported its own
# SQLCMDPASSWORD, and deleting it would break the rest of that parent's run.
Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue
Assert-Equal -Expected 'secret' -Actual (Invoke-WithDbPassword -Name SQLCMDPASSWORD -Password 'secret' -Action { $env:SQLCMDPASSWORD }) -Because 'the password is visible to the action'
Assert-Equal -Expected 'False' -Actual "$(Test-Path Env:SQLCMDPASSWORD)" -Because 'a variable that did not exist before is removed afterwards'
$env:SQLCMDPASSWORD = 'from-the-parent'
[void](Invoke-WithDbPassword -Name SQLCMDPASSWORD -Password 'secret' -Action { $env:SQLCMDPASSWORD })
Assert-Equal -Expected 'from-the-parent' -Actual "$env:SQLCMDPASSWORD" -Because "a parent's value is put back, not deleted"
Assert-Throws -Because 'an error inside the action still propagates' -Matching 'boom' -Action {
    Invoke-WithDbPassword -Name SQLCMDPASSWORD -Password 'secret' -Action { throw 'boom' }
}
Assert-Equal -Expected 'from-the-parent' -Actual "$env:SQLCMDPASSWORD" -Because "a parent's value is put back even when the action throws"
Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Both folders' helpers agree (they are separate copies)" -ForegroundColor Cyan
# quick-start/ and edorg-sync/ each dot-source their own compat.ps1, so the
# certificate decision lives in two places and could drift. Dot-sourcing the
# other copy inside & { } scopes its functions to that block, so the two
# implementations can be run over the same inputs and compared here.
$hostMatrix = @('localhost', 'tcp:localhost,1433', '(local)', '.', '127.0.0.1', '[::1]',
                'localhost\SQLEXPRESS', 'np:\\.\pipe\sql\query', $env:COMPUTERNAME, '',
                'myserver.database.windows.net', 'tcp:myserver.database.windows.net,1433',
                '10.0.0.5', 'sqlbox', 'sqlbox\SQLEXPRESS')
$thisFolder = foreach ($h in $hostMatrix) {
    '{0}|{1}|{2}' -f $h, ((Get-SqlcmdTrustArgs -SqlServer $h) -join ' '), ((Get-SqlcmdTrustArgs -SqlServer $h -TrustServerCertificate) -join ' ')
}
$otherFolder = & {
    . "$PSScriptRoot/../../edorg-sync/compat.ps1"
    foreach ($h in $hostMatrix) {
        '{0}|{1}|{2}' -f $h, ((Get-SqlcmdTrustArgs -SqlServer $h) -join ' '), ((Get-SqlcmdTrustArgs -SqlServer $h -TrustServerCertificate) -join ' ')
    }
}
Assert-Equal -Expected ($thisFolder -join "`n") -Actual ($otherFolder -join "`n") -Because "edorg-sync/compat.ps1 returns the same flags for all $($hostMatrix.Count) targets"

Write-Host ""
Write-Host ("{0} passed, {1} failed." -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed) { 'Red' } else { 'Green' })
if ($script:Failed) { exit 1 }
exit 0
