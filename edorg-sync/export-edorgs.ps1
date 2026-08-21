<#
.SYNOPSIS
  Export education organizations from an EdFi_ODS database to a CSV file, for
  a one-time bulk import into the Admin App database with import-edorgs.ps1.

.DESCRIPTION
  Queries edfi.EducationOrganization plus the subtype tables that carry each
  organization's place in the hierarchy and writes one CSV row per education
  organization:

    educationOrganizationId,nameOfInstitution,shortNameOfInstitution,
    discriminator,parentEducationOrganizationId

  The discriminator column is the education organization TYPE exactly as the
  ODS stores it (e.g. 'edfi.School', 'edfi.LocalEducationAgency') and is what
  the Admin App uses to tell types apart. The parent id is derived per type:

    * School                -> LocalEducationAgencyId
    * LocalEducationAgency  -> ParentLocalEducationAgencyId, else
                               EducationServiceCenterId, else
                               StateEducationAgencyId
    * EducationServiceCenter-> StateEducationAgencyId
    * OrganizationDepartment-> ParentEducationOrganizationId
    * everything else       -> none (root)

  Every education organization in the ODS is exported, including types the
  Admin App does not support (e.g. edfi.CommunityOrganization) -- those are
  reported here and skipped later by import-edorgs.ps1. Read-only: the script
  never writes to the ODS.

  This is a temporary bridge for Admin App v4.0 deployments whose ed orgs
  predate the Admin App; Admin App v4.1 is slated to sync ed orgs natively.

.PARAMETER OdsDatabaseName
  The ODS database to export from (e.g. EdFi_Ods_2026,
  EdFi_Ods_Populated_Template).

.PARAMETER OutputPath
  Where to write the CSV (default edorgs.csv next to this script).

.PARAMETER DbEngine
  ODS database engine: 'mssql' (default) or 'pgsql'.

.PARAMETER SqlServer
  mssql only: the SQL Server to connect to (default 'tcp:localhost,1433'). The
  ODS is provisioned by the ODS/API installation, so it may not be on this
  machine.

.PARAMETER DbUsername
  mssql only: SQL login (default 'sa').

.PARAMETER DbPassword
  mssql only: password for -DbUsername; required unless -UseIntegratedSecurity.
  Passed to sqlcmd through the SQLCMDPASSWORD environment variable, never on a
  command line.

.PARAMETER UseIntegratedSecurity
  mssql only: connect with Windows integrated authentication instead of
  -DbUsername/-DbPassword.

.PARAMETER PostgresPassword
  pgsql only: password for -PostgresUser; required when -DbEngine is 'pgsql'.
  Passed to psql through the PGPASSWORD environment variable, never on a
  command line.

.PARAMETER PostgresHost
  pgsql only: PostgreSQL host (default 'localhost'). Ignored with
  -UsePostgresDocker.

.PARAMETER PostgresPort
  pgsql only: PostgreSQL port (default 5432). Ignored with -UsePostgresDocker.

.PARAMETER PostgresUser
  pgsql only: PostgreSQL login (default 'postgres').

.PARAMETER UsePostgresDocker
  pgsql only: run psql inside the ODS Docker stack's database container
  instead of a host psql.

.PARAMETER PostgresContainerName
  pgsql only: the Docker database container name (default 'ed-fi-db-ods').
  Only used with -UsePostgresDocker.

.EXAMPLE
  # SQL Server (default engine):
  ./export-edorgs.ps1 -OdsDatabaseName 'EdFi_Ods_2026' -DbPassword 'EdFi-Local!2026'

.EXAMPLE
  # SQL Server with Windows integrated authentication (e.g. a local initdev
  # environment):
  ./export-edorgs.ps1 -OdsDatabaseName 'EdFi_Ods_Populated_Template' -UseIntegratedSecurity

.EXAMPLE
  # PostgreSQL:
  ./export-edorgs.ps1 -DbEngine pgsql -OdsDatabaseName 'EdFi_Ods_2026' -PostgresPassword 'P@ssw0rd'

.EXAMPLE
  # PostgreSQL running in the ODS Docker stack:
  ./export-edorgs.ps1 -DbEngine pgsql -OdsDatabaseName 'EdFi_Ods_2026' `
    -PostgresPassword 'P@ssw0rd' -UsePostgresDocker
#>
#requires -Version 5.1
param(
    # The ODS database to export from (e.g. EdFi_Ods_2026, EdFi_Ods_Populated_Template).
    [Parameter(Mandatory = $true)][string]$OdsDatabaseName,
    # Where to write the CSV.
    [string]$OutputPath = "$PSScriptRoot/edorgs.csv",

    [ValidateSet('mssql', 'pgsql')][string]$DbEngine = 'mssql',

    # --- mssql -----------------------------------------------------------------
    # The ODS is provisioned by the ODS/API installation, so it may not be on
    # this machine -- server and login are parameterized.
    [string]$SqlServer = 'tcp:localhost,1433',
    [string]$DbUsername = 'sa',
    [string]$DbPassword,                         # required for -DbEngine mssql unless -UseIntegratedSecurity
    [switch]$UseIntegratedSecurity,
    # Trust the server certificate without validating it. Applied automatically
    # for a loopback -SqlServer (the local self-signed instance); required only
    # to reach a REMOTE server whose certificate is self-signed or otherwise
    # not chain-trusted. It disables validation, so the connection becomes
    # vulnerable to a machine-in-the-middle -- prefer a trusted certificate.
    [switch]$TrustServerCertificate,

    # --- pgsql -----------------------------------------------------------------
    [string]$PostgresPassword,                   # required for -DbEngine pgsql
    [string]$PostgresHost = 'localhost',
    [int]$PostgresPort = 5432,
    [string]$PostgresUser = 'postgres',
    [switch]$UsePostgresDocker,
    # The ODS Docker stack's ODS database container.
    [string]$PostgresContainerName = 'ed-fi-db-ods'
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/compat.ps1"

# Engine-specific required-arg validation.
if ($DbEngine -eq 'mssql' -and -not $UseIntegratedSecurity -and -not $DbPassword) { throw "-DbPassword is required when -DbEngine is 'mssql' (the default) without -UseIntegratedSecurity." }
if ($UseIntegratedSecurity -and $DbEngine -ne 'mssql') { throw "-UseIntegratedSecurity only applies when -DbEngine is 'mssql'." }
# Windows authentication cannot reach a managed Azure SQL Database. Fail here
# rather than at the sqlcmd call, which reports it as a raw driver error.
Assert-SqlAuthSupported -SqlServer $SqlServer -UseIntegratedSecurity ([bool]$UseIntegratedSecurity) `
    -UsernameParameterName '-DbUsername' -PasswordParameterName '-DbPassword'
if ($DbEngine -eq 'pgsql' -and -not $PostgresPassword) { throw "-PostgresPassword is required when -DbEngine is 'pgsql'." }
if ($UsePostgresDocker -and $DbEngine -ne 'pgsql') { throw "-UsePostgresDocker only applies when -DbEngine is 'pgsql'." }

# Ed org types the Admin App understands (packages/models edorg-type enum);
# anything else is exported but flagged, and skipped by import-edorgs.ps1.
$supportedDiscriminators = @(
    'edfi.StateEducationAgency', 'edfi.EducationServiceCenter',
    'edfi.LocalEducationAgency', 'edfi.School',
    'edfi.EducationOrganizationNetwork', 'edfi.PostSecondaryInstitution',
    'edfi.OrganizationDepartment', 'edfi.Other'
)

Write-Host "Exporting education organizations from $DbEngine db '$OdsDatabaseName'..."

$rows = @()
if ($DbEngine -eq 'mssql')
{
    # The @(...) wrap is load-bearing: assignment from an if-expression unrolls
    # a one-element array to a scalar string, and splatting a scalar to a
    # native command garbles the argument list. The password travels via
    # SQLCMDPASSWORD (set just before the call), never as -P, so it stays off
    # the sqlcmd process command line (visible in the process list).
    $authArgs = @(if ($UseIntegratedSecurity) { '-E' } else { '-U', $DbUsername })

    # -C (trust server certificate) only where it is safe: a loopback target or
    # an explicit opt-in. Same @(...) rule as $authArgs above.
    $trustArgs = @(Get-SqlcmdTrustArgs -SqlServer $SqlServer -TrustServerCertificate:$TrustServerCertificate)

    # FOR JSON sidesteps sqlcmd's column formatting entirely: the result is a
    # single JSON document (wrapped across output lines) that round-trips names
    # containing commas or quotes safely.
    $sql = @"
SET NOCOUNT ON;
SELECT eo.EducationOrganizationId AS educationOrganizationId,
       eo.NameOfInstitution AS nameOfInstitution,
       eo.ShortNameOfInstitution AS shortNameOfInstitution,
       eo.Discriminator AS discriminator,
       COALESCE(s.LocalEducationAgencyId,
                lea.ParentLocalEducationAgencyId, lea.EducationServiceCenterId, lea.StateEducationAgencyId,
                esc.StateEducationAgencyId,
                od.ParentEducationOrganizationId) AS parentEducationOrganizationId
FROM edfi.EducationOrganization eo
    LEFT JOIN edfi.School s ON s.SchoolId = eo.EducationOrganizationId
    LEFT JOIN edfi.LocalEducationAgency lea ON lea.LocalEducationAgencyId = eo.EducationOrganizationId
    LEFT JOIN edfi.EducationServiceCenter esc ON esc.EducationServiceCenterId = eo.EducationOrganizationId
    LEFT JOIN edfi.OrganizationDepartment od ON od.OrganizationDepartmentId = eo.EducationOrganizationId
ORDER BY eo.EducationOrganizationId
FOR JSON PATH, INCLUDE_NULL_VALUES;
"@
    # -y 0 stops sqlcmd truncating the (long) JSON column (and excludes -h -1,
    # so a header line comes along); the document also arrives wrapped across
    # lines. Join everything and cut from the first '[' to the last ']'.
    # Invoke-WithDbPassword restores whatever SQLCMDPASSWORD held before rather
    # than deleting it: a parent automation process may have exported its own.
    $raw = Invoke-WithDbPassword -Name SQLCMDPASSWORD -Password $(if ($UseIntegratedSecurity) { '' } else { $DbPassword }) -Action {
        & sqlcmd -S $SqlServer @authArgs @trustArgs -d $OdsDatabaseName -b -y 0 -Q $sql
    }
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed (exit $LASTEXITCODE). Check -SqlServer / -DbUsername / -DbPassword / -OdsDatabaseName. If it reports that the certificate chain is not trusted, the server uses a self-signed certificate: pass -TrustServerCertificate (or set SQL_TRUST_SERVER_CERTIFICATE=true in the .env)." }
    $joined = @($raw) -join ''
    $start = $joined.IndexOf('[')
    $end = $joined.LastIndexOf(']')
    if ($start -ge 0 -and $end -gt $start)
    {
        # Assign before @(): on Windows PowerShell 5.1 ConvertFrom-Json emits
        # the parsed array as a SINGLE pipeline object, so @() directly around
        # the pipeline would wrap the whole array as one element.
        $parsed = $joined.Substring($start, $end - $start + 1) | ConvertFrom-Json
        $rows = @($parsed)
    }
}
else
{
    # COPY ... TO STDOUT emits real CSV (quoting included), which ConvertFrom-Csv
    # parses back into objects; identifiers are lowercase in the PostgreSQL ODS.
    $sql = @"
COPY (
    SELECT eo.educationorganizationid AS "educationOrganizationId",
           eo.nameofinstitution AS "nameOfInstitution",
           eo.shortnameofinstitution AS "shortNameOfInstitution",
           eo.discriminator AS "discriminator",
           COALESCE(s.localeducationagencyid,
                    lea.parentlocaleducationagencyid, lea.educationservicecenterid, lea.stateeducationagencyid,
                    esc.stateeducationagencyid,
                    od.parenteducationorganizationid) AS "parentEducationOrganizationId"
    FROM edfi.educationorganization eo
        LEFT JOIN edfi.school s ON s.schoolid = eo.educationorganizationid
        LEFT JOIN edfi.localeducationagency lea ON lea.localeducationagencyid = eo.educationorganizationid
        LEFT JOIN edfi.educationservicecenter esc ON esc.educationservicecenterid = eo.educationorganizationid
        LEFT JOIN edfi.organizationdepartment od ON od.organizationdepartmentid = eo.educationorganizationid
    ORDER BY eo.educationorganizationid
) TO STDOUT WITH (FORMAT csv, HEADER true);
"@
    # Pass the password through the environment, never on the command line:
    # `docker exec -e PGPASSWORD` (no value) forwards it from this process, so
    # the secret stays out of the docker argv. Restored afterwards, not deleted.
    $raw = Invoke-WithDbPassword -Name PGPASSWORD -Password $PostgresPassword -Action {
        if ($UsePostgresDocker)
        {
            $sql | & docker exec -i -e PGPASSWORD $PostgresContainerName psql -U $PostgresUser -d $OdsDatabaseName -v ON_ERROR_STOP=1
        }
        else
        {
            $sql | & psql -h $PostgresHost -p $PostgresPort -U $PostgresUser -d $OdsDatabaseName -v ON_ERROR_STOP=1
        }
    }
    if ($LASTEXITCODE -ne 0) { throw "psql failed (exit $LASTEXITCODE). Check -PostgresPassword / -PostgresHost / -PostgresPort / -PostgresUser / -OdsDatabaseName." }
    if (@($raw).Count -gt 1) { $rows = @($raw | ConvertFrom-Csv) }
}

if ($rows.Count -eq 0) { throw "No education organizations found in '$OdsDatabaseName'. Check the database name (and that the ODS has been loaded with data)." }

# Normalize to a fixed column order and write the CSV. Export-Csv handles
# quoting; nulls become empty fields.
$rows | ForEach-Object {
    [pscustomobject]@{
        educationOrganizationId       = $_.educationOrganizationId
        nameOfInstitution             = $_.nameOfInstitution
        shortNameOfInstitution        = $_.shortNameOfInstitution
        discriminator                 = $_.discriminator
        parentEducationOrganizationId = $_.parentEducationOrganizationId
    }
} | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding utf8

Write-Host "`nExported $($rows.Count) education organizations by type:"
$rows | Group-Object discriminator | Sort-Object Name | ForEach-Object {
    $name = if ($_.Name) { $_.Name } else { '(no discriminator)' }
    $flag = if ($_.Name -in $supportedDiscriminators) { '' } else { '  <- not supported by the Admin App; import-edorgs.ps1 will skip these' }
    Write-Host ("  {0,-40} {1,6}{2}" -f $name, $_.Count, $flag)
}

Write-Host "`nSUCCESS: wrote $OutputPath" -ForegroundColor Green
Write-Host "Next:" -ForegroundColor Green
Write-Host "  1. Review the CSV (optionally remove rows you do not want in the Admin App)."
Write-Host "  2. Load it into the Admin App database:"
Write-Host "       ./import-edorgs.ps1 -CsvPath '$OutputPath' ..."
