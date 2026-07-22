#requires -Version 7.0
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

# Engine-specific required-arg validation.
if ($DbEngine -eq 'mssql' -and -not $UseIntegratedSecurity -and -not $DbPassword) { throw "-DbPassword is required when -DbEngine is 'mssql' (the default) without -UseIntegratedSecurity." }
if ($UseIntegratedSecurity -and $DbEngine -ne 'mssql') { throw "-UseIntegratedSecurity only applies when -DbEngine is 'mssql'." }
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
    # native command garbles the argument list.
    $authArgs = @(if ($UseIntegratedSecurity) { '-E' } else { '-U', $DbUsername, '-P', $DbPassword })

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
    $raw = & sqlcmd -S $SqlServer @authArgs -d $OdsDatabaseName -b -y 0 -Q $sql
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed (exit $LASTEXITCODE). Check -SqlServer / -DbUsername / -DbPassword / -OdsDatabaseName." }
    $joined = @($raw) -join ''
    $start = $joined.IndexOf('[')
    $end = $joined.LastIndexOf(']')
    if ($start -ge 0 -and $end -gt $start)
    {
        $rows = @($joined.Substring($start, $end - $start + 1) | ConvertFrom-Json)
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
    if ($UsePostgresDocker)
    {
        $raw = $sql | & docker exec -i -e "PGPASSWORD=$PostgresPassword" $PostgresContainerName psql -U $PostgresUser -d $OdsDatabaseName -v ON_ERROR_STOP=1
    }
    else
    {
        $env:PGPASSWORD = $PostgresPassword
        $raw = $sql | & psql -h $PostgresHost -p $PostgresPort -U $PostgresUser -d $OdsDatabaseName -v ON_ERROR_STOP=1
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
