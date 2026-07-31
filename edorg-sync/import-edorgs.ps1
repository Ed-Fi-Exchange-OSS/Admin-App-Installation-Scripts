<#
.SYNOPSIS
  Load education organizations from a CSV (produced by export-edorgs.ps1) into
  the Admin App application database. Idempotent.

.DESCRIPTION
  One-time bulk import of pre-existing ODS education organizations into the
  Admin App's edorg table, so they show up when creating a new Application.
  Mirrors what the Admin App's own sync writes: one edorg row per education
  organization (type carried in the discriminator column), the parent/child
  hierarchy in parentId, and the ancestor/self rows in edorg_closure that the
  Admin App's tree queries rely on.

  The rows are attached to an EXISTING tenant + ODS registration in the Admin
  App database: the script looks up the edfi_tenant named -TenantName and its
  ods row (matched by -OdsDbName when the tenant has more than one), then
  stamps every imported row with that tenant/environment/ODS scope. Register
  the environment, tenant, and ODS instances first through the Admin App UI.

  Import rules, per CSV row:

    * discriminator must be an ed org type the Admin App supports
      (edfi.School, edfi.LocalEducationAgency, edfi.StateEducationAgency,
      edfi.EducationServiceCenter, edfi.EducationOrganizationNetwork,
      edfi.PostSecondaryInstitution, edfi.OrganizationDepartment, edfi.Other);
      other types are skipped with a warning.
    * an education organization that already exists in the scope (same
      tenant + ODS + educationOrganizationId) keeps its row, but its name,
      short name, and type are corrected to the CSV values when they differ --
      the same three columns the Admin App's own sync maintains. This fixes
      the 'Institution #<id>' / edfi.Other placeholder rows the Admin App
      writes when an ODS is registered with allowed ed orgs. Re-runs are
      no-ops.
    * the parent link is resolved inside the same scope, whether the parent
      came from this CSV or already existed; a parent that cannot be found
      leaves the row a root (warned). Parent links on pre-existing rows are
      never clobbered.
    * the ids actually INSERTED are recorded in imported-ids.csv next to the
      CSV; cleanup-edorgs.ps1 deletes only ids recorded there.

  The whole load runs in a single transaction: on any error nothing is
  imported.

  NOTE: on SQL Server the Admin App schema stores educationOrganizationId as
  a 32-bit int, so ids above 2,147,483,647 cannot be imported (the script
  stops and lists them). PostgreSQL stores bigint and has no such limit.

.PARAMETER CsvPath
  CSV produced by export-edorgs.ps1, or hand-authored with the same columns.

.PARAMETER TenantName
  Admin App tenant to import into (edfi_tenant.name); 'default' unless the
  deployment renamed it.

.PARAMETER EnvironmentName
  Environment name (sb_environment.name); only needed when the same tenant
  name exists in more than one environment.

.PARAMETER OdsDbName
  Which registered ODS to attach the ed orgs to (ods.dbName); only needed when
  the tenant has more than one ODS registered.

.PARAMETER DbEngine
  Admin App database engine: 'mssql' (default) or 'pgsql'.

.PARAMETER DatabaseName
  The Admin App application database (default 'sbaa').

.PARAMETER SqlServer
  mssql only: the SQL Server to connect to (default 'tcp:localhost,1433').

.PARAMETER DbUsername
  mssql only: SQL login (default 'edfi_adminapp').

.PARAMETER DbPassword
  mssql only: password for -DbUsername; required unless -UseIntegratedSecurity.
  Passed to sqlcmd through the SQLCMDPASSWORD environment variable, never on a
  command line.

.PARAMETER UseIntegratedSecurity
  mssql only: connect with Windows integrated authentication instead of
  -DbUsername/-DbPassword.

.PARAMETER PostgresAppPassword
  pgsql only: password for -PostgresAppUser; required when -DbEngine is
  'pgsql'. Passed to psql through the PGPASSWORD environment variable, never
  on a command line.

.PARAMETER PostgresHost
  pgsql only: PostgreSQL host (default 'localhost'). Ignored with
  -UsePostgresDocker.

.PARAMETER PostgresPort
  pgsql only: PostgreSQL port (default 5432). Ignored with -UsePostgresDocker.

.PARAMETER PostgresAppUser
  pgsql only: PostgreSQL login (default 'edfiadminapp').

.PARAMETER UsePostgresDocker
  pgsql only: run psql inside the Admin App Docker stack's database container
  instead of a host psql.

.PARAMETER PostgresContainerName
  pgsql only: the Docker database container name (default
  'edfiadminapp-postgres'). Only used with -UsePostgresDocker.

.EXAMPLE
  # SQL Server (default engine), default tenant, single registered ODS:
  ./import-edorgs.ps1 -DbPassword 'EdFi-Local!2026'

.EXAMPLE
  # Tenant with several registered ODS databases -- pick one:
  ./import-edorgs.ps1 -DbPassword '...' -OdsDbName 'EdFi_Ods_2026'

.EXAMPLE
  # PostgreSQL (the Admin App Docker stack):
  ./import-edorgs.ps1 -DbEngine pgsql -PostgresAppPassword 'P@ssw0rd' -UsePostgresDocker

.EXAMPLE
  # Different CSV and a named environment:
  ./import-edorgs.ps1 -CsvPath ./district-edorgs.csv -EnvironmentName 'Ed-Fi ODS/API v7.3' -DbPassword '...'
#>
#requires -Version 5.1
param(
    # CSV produced by export-edorgs.ps1 (or hand-authored with the same columns).
    [string]$CsvPath = "$PSScriptRoot/edorgs.csv",

    # Admin App tenant to import into (edfi_tenant.name; 'default' unless the
    # deployment renamed it).
    [string]$TenantName = 'default',
    # Optional: environment name (sb_environment.name), only needed when the
    # same tenant name exists in more than one environment.
    [string]$EnvironmentName,
    # Optional: which registered ODS to attach the ed orgs to (ods.dbName),
    # only needed when the tenant has more than one ODS registered.
    [string]$OdsDbName,

    [ValidateSet('mssql', 'pgsql')][string]$DbEngine = 'mssql',
    # The Admin App application database.
    [string]$DatabaseName = 'sbaa',

    # --- mssql -----------------------------------------------------------------
    [string]$SqlServer = 'tcp:localhost,1433',
    [string]$DbUsername = 'edfi_adminapp',
    [string]$DbPassword,                         # required for -DbEngine mssql unless -UseIntegratedSecurity
    [switch]$UseIntegratedSecurity,
    # Trust the server certificate without validating it. Applied automatically
    # for a loopback -SqlServer (the local self-signed instance); required only
    # to reach a REMOTE server whose certificate is self-signed or otherwise
    # not chain-trusted. It disables validation, so the connection becomes
    # vulnerable to a machine-in-the-middle -- prefer a trusted certificate.
    [switch]$TrustServerCertificate,

    # --- pgsql -----------------------------------------------------------------
    [string]$PostgresAppPassword,                # required for -DbEngine pgsql
    [string]$PostgresHost = 'localhost',
    [int]$PostgresPort = 5432,
    [string]$PostgresAppUser = 'edfiadminapp',
    [switch]$UsePostgresDocker,
    # The Admin App Docker stack's database container.
    [string]$PostgresContainerName = 'edfiadminapp-postgres'
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/compat.ps1"

# Engine-specific required-arg validation.
if ($DbEngine -eq 'mssql' -and -not $UseIntegratedSecurity -and -not $DbPassword) { throw "-DbPassword is required when -DbEngine is 'mssql' (the default) without -UseIntegratedSecurity." }
if ($UseIntegratedSecurity -and $DbEngine -ne 'mssql') { throw "-UseIntegratedSecurity only applies when -DbEngine is 'mssql'." }
if ($DbEngine -eq 'pgsql' -and -not $PostgresAppPassword) { throw "-PostgresAppPassword is required when -DbEngine is 'pgsql'." }
if ($UsePostgresDocker -and $DbEngine -ne 'pgsql') { throw "-UsePostgresDocker only applies when -DbEngine is 'pgsql'." }
if (-not (Test-Path $CsvPath)) { throw "CSV not found: $CsvPath. Run export-edorgs.ps1 first (or pass -CsvPath)." }

if ($DbEngine -eq 'mssql')
{
    # The @(...) wrap is load-bearing: assignment from an if-expression unrolls
    # a one-element array to a scalar string, and splatting a scalar to a
    # native command garbles the argument list. The password travels via
    # SQLCMDPASSWORD (set around each call), never as -P, so it stays off
    # the sqlcmd process command line (visible in the process list).
    $authArgs = @(if ($UseIntegratedSecurity) { '-E' } else { '-U', $DbUsername })

    # -C (trust server certificate) only where it is safe: a loopback target or
    # an explicit opt-in. Same @(...) rule as $authArgs above.
    $trustArgs = @(Get-SqlcmdTrustArgs -SqlServer $SqlServer -TrustServerCertificate:$TrustServerCertificate)
}

function Invoke-AdminAppSql
{
    # Runs SQL against the Admin App database and returns raw output lines.
    # mssql reads from a temp file (-i): the generated batch can exceed the
    # command-line length -Q allows. pgsql reads from stdin.
    param([Parameter(Mandatory = $true)][string]$Sql, [string]$FailHint)

    if ($DbEngine -eq 'mssql')
    {
        $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("edorg-import-{0}.sql" -f [guid]::NewGuid())
        try
        {
            # UTF-8 with BOM so sqlcmd decodes non-ASCII institution names
            # correctly ('utf8BOM' is not a valid encoding name on 5.1).
            Write-Utf8BomFile -Path $tempFile -Content $Sql
            if (-not $UseIntegratedSecurity) { $env:SQLCMDPASSWORD = $DbPassword }
            $out = & sqlcmd -S $SqlServer @authArgs @trustArgs -d $DatabaseName -b -h -1 -W -s '|' -i $tempFile
            if ($LASTEXITCODE -ne 0)
            {
                $out | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
                throw "sqlcmd failed (exit $LASTEXITCODE). $FailHint If the output above reports that the certificate chain is not trusted, the server uses a self-signed certificate: pass -TrustServerCertificate (or set SQL_TRUST_SERVER_CERTIFICATE=true in the .env)."
            }
            return $out
        }
        finally
        {
            Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
        }
    }

    # Pass the password through the environment, never on the command line:
    # `docker exec -e PGPASSWORD` (no value) forwards it from this process, so
    # the secret stays out of the docker argv; cleared in the finally.
    $env:PGPASSWORD = $PostgresAppPassword
    try
    {
        if ($UsePostgresDocker)
        {
            $out = $Sql | & docker exec -i -e PGPASSWORD $PostgresContainerName psql -U $PostgresAppUser -d $DatabaseName -v ON_ERROR_STOP=1 -t -A -F '|'
        }
        else
        {
            $out = $Sql | & psql -h $PostgresHost -p $PostgresPort -U $PostgresAppUser -d $DatabaseName -v ON_ERROR_STOP=1 -t -A -F '|'
        }
    }
    finally
    {
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    }
    if ($LASTEXITCODE -ne 0)
    {
        $out | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        throw "psql failed (exit $LASTEXITCODE). $FailHint"
    }
    return $out
}

# Ed org types the Admin App understands (packages/models edorg-type enum).
$supportedDiscriminators = @(
    'edfi.StateEducationAgency', 'edfi.EducationServiceCenter',
    'edfi.LocalEducationAgency', 'edfi.School',
    'edfi.EducationOrganizationNetwork', 'edfi.PostSecondaryInstitution',
    'edfi.OrganizationDepartment', 'edfi.Other'
)

# ---- Step 1: read and validate the CSV ---------------------------------------
Write-Host "Reading $CsvPath..."
# -Encoding UTF8 matters on Windows PowerShell 5.1, where the default is ANSI
# and a BOM-less UTF-8 CSV (as PS7's export writes) would be misread.
$csv = @(Import-Csv -Path $CsvPath -Encoding UTF8)
if ($csv.Count -eq 0) { throw "CSV is empty: $CsvPath" }
foreach ($required in 'educationOrganizationId', 'nameOfInstitution', 'discriminator')
{
    if ($required -notin $csv[0].PSObject.Properties.Name) { throw "CSV is missing the '$required' column. Expected the columns written by export-edorgs.ps1." }
}

# List, not array +=: appending to an array reallocates it every time, which
# is quadratic in CSV size.
$rows = [System.Collections.Generic.List[object]]::new()
$skippedByType = @{}
foreach ($r in $csv)
{
    $disc = "$($r.discriminator)".Trim()
    if ($disc -notin $supportedDiscriminators)
    {
        $key = if ($disc) { $disc } else { '(no discriminator)' }
        $skippedByType[$key] = 1 + $skippedByType[$key]
        continue
    }
    if ("$($r.educationOrganizationId)" -notmatch '^\d+$') { throw "Row with nameOfInstitution '$($r.nameOfInstitution)' has a non-numeric educationOrganizationId '$($r.educationOrganizationId)'." }
    if (-not "$($r.nameOfInstitution)".Trim()) { throw "Row with educationOrganizationId $($r.educationOrganizationId) has an empty nameOfInstitution." }
    $rows.Add([pscustomobject]@{
            EdOrgId       = [long]$r.educationOrganizationId
            Name          = "$($r.nameOfInstitution)".Trim()
            ShortName     = "$($r.shortNameOfInstitution)".Trim()
            Discriminator = $disc
            ParentEdOrgId = if ("$($r.parentEducationOrganizationId)" -match '^\d+$') { [long]$r.parentEducationOrganizationId } else { $null }
        })
}

foreach ($entry in $skippedByType.GetEnumerator() | Sort-Object Key)
{
    Write-Host "WARNING: skipping $($entry.Value) row(s) of type '$($entry.Key)' -- not supported by the Admin App." -ForegroundColor Yellow
}
if ($rows.Count -eq 0) { throw "No importable rows: every row in the CSV has an unsupported discriminator." }

$duplicates = @($rows | Group-Object EdOrgId | Where-Object Count -gt 1)
if ($duplicates.Count -gt 0) { throw "Duplicate educationOrganizationId value(s) in the CSV: $(($duplicates | ForEach-Object Name) -join ', ')." }

# Self-parents and parent cycles would only surface later as an opaque
# recursion error from the closure CTE (SQL Server stops at MAXRECURSION 100;
# PostgreSQL has no depth cap at all), so reject them during validation. The
# CSV is hand-editable per the docs, which makes this reachable in practice.
$parentOf = @{}
foreach ($row in $rows) { $parentOf[$row.EdOrgId] = $row.ParentEdOrgId }
$acyclic = [System.Collections.Generic.HashSet[long]]::new()
foreach ($row in $rows)
{
    if ($row.ParentEdOrgId -eq $row.EdOrgId) { throw "Row with educationOrganizationId $($row.EdOrgId) lists itself as its parent." }
    $walk = [System.Collections.Generic.HashSet[long]]::new()
    $cur = $row.EdOrgId
    while ($null -ne $cur -and $parentOf.ContainsKey($cur) -and -not $acyclic.Contains([long]$cur))
    {
        if (-not $walk.Add([long]$cur)) { throw "Parent cycle in the CSV involving educationOrganizationId(s): $(@($walk | Sort-Object) -join ', ')." }
        $cur = $parentOf[$cur]
    }
    $acyclic.UnionWith($walk)
}

# On SQL Server the Admin App stores educationOrganizationId as a 32-bit int.
if ($DbEngine -eq 'mssql')
{
    $tooBig = @($rows | Where-Object { $_.EdOrgId -gt 2147483647 })
    if ($tooBig.Count -gt 0)
    {
        throw ("educationOrganizationId value(s) exceed the SQL Server Admin App schema's int range (max 2147483647): " +
            "$(($tooBig | ForEach-Object EdOrgId) -join ', '). Remove these rows from the CSV, or use a PostgreSQL Admin App database.")
    }
}

# Parents that are neither in the CSV nor (necessarily) in the database: the
# row still imports, but as a root unless the parent already exists in the
# Admin App under the same tenant/ODS.
$idsInCsv = [System.Collections.Generic.HashSet[long]]::new([long[]]@($rows | ForEach-Object EdOrgId))
$missingParents = @($rows | Where-Object { $null -ne $_.ParentEdOrgId -and -not $idsInCsv.Contains([long]$_.ParentEdOrgId) } |
        ForEach-Object ParentEdOrgId | Sort-Object -Unique)
if ($missingParents.Count -gt 0)
{
    Write-Host "NOTE: parent id(s) $($missingParents -join ', ') are referenced but not in the CSV; children link to them only if they already exist in the Admin App database (otherwise they import as roots)." -ForegroundColor Yellow
}

Write-Host "  $($rows.Count) education organizations to import."

# ---- Step 2: resolve the tenant / ODS scope ----------------------------------
Write-Host "`nResolving tenant '$TenantName'$(if ($EnvironmentName) { " in environment '$EnvironmentName'" }) in $DbEngine db '$DatabaseName'..."
$tenantNameSql = $TenantName.Replace("'", "''")
$envNameSql = $EnvironmentName.Replace("'", "''")
$odsDbNameSql = $OdsDbName.Replace("'", "''")

# The scope row comes back as ONE concatenated column with a multi-character
# delimiter, so an environment or ODS name that itself contains '|' (the
# sqlcmd/psql field separator) cannot shift the fields.
$scopeDelim = '|~|'
if ($DbEngine -eq 'mssql')
{
    $envFilter = if ($EnvironmentName) { "AND e.[name] = N'$envNameSql'" } else { '' }
    $odsFilter = if ($OdsDbName) { "AND o.[dbName] = N'$odsDbNameSql'" } else { '' }
    $scopeSql = @"
SET NOCOUNT ON;
SELECT CONCAT(t.[id], '$scopeDelim', t.[sbEnvironmentId], '$scopeDelim', e.[name], '$scopeDelim',
              o.[id], '$scopeDelim', o.[dbName], '$scopeDelim',
              COALESCE(CAST(o.[odsInstanceId] AS nvarchar(20)), N''))
FROM [edfi_tenant] t
    INNER JOIN [sb_environment] e ON e.[id] = t.[sbEnvironmentId]
    INNER JOIN [ods] o ON o.[edfiTenantId] = t.[id]
WHERE t.[name] = N'$tenantNameSql'
    $envFilter
    $odsFilter;
"@
}
else
{
    $envFilter = if ($EnvironmentName) { "AND e.name = '$envNameSql'" } else { '' }
    $odsFilter = if ($OdsDbName) { 'AND o."dbName" = ' + "'$odsDbNameSql'" } else { '' }
    $scopeSql = @"
SELECT CONCAT(t.id, '$scopeDelim', t."sbEnvironmentId", '$scopeDelim', e.name, '$scopeDelim',
              o.id, '$scopeDelim', o."dbName", '$scopeDelim',
              COALESCE(CAST(o."odsInstanceId" AS varchar), ''))
FROM edfi_tenant t
    JOIN sb_environment e ON e.id = t."sbEnvironmentId"
    JOIN ods o ON o."edfiTenantId" = t.id
WHERE t.name = '$tenantNameSql'
    $envFilter
    $odsFilter;
"@
}

$scopeRows = @(Invoke-AdminAppSql -Sql $scopeSql -FailHint 'Check the connection parameters and -DatabaseName.' |
        ForEach-Object { "$_".Trim() } | Where-Object { $_ -and $_.Contains($scopeDelim) })

if ($scopeRows.Count -eq 0)
{
    throw ("No registered ODS found for tenant '$TenantName'$(if ($EnvironmentName) { " in environment '$EnvironmentName'" })$(if ($OdsDbName) { " with dbName '$OdsDbName'" }) in '$DatabaseName'. " +
        'Register the environment, tenant, and ODS instances first through the Admin App UI.')
}
if ($scopeRows.Count -gt 1)
{
    $candidates = ($scopeRows | ForEach-Object { $p = $_ -split [regex]::Escape($scopeDelim); "environment '$($p[2])' / ods dbName '$($p[4])'" }) -join '; '
    throw "Tenant '$TenantName' matches more than one scope: $candidates. Disambiguate with -OdsDbName (and -EnvironmentName if needed)."
}

$parts = $scopeRows[0] -split [regex]::Escape($scopeDelim)
$tenantId = [int]$parts[0]
$sbEnvironmentId = [int]$parts[1]
$resolvedEnvName = $parts[2]
$odsId = [int]$parts[3]
$resolvedOdsDbName = $parts[4]
$odsInstanceId = if ($parts[5]) { [long]$parts[5] } else { $null }
$odsInstanceIdSql = if ($null -ne $odsInstanceId) { $odsInstanceId } else { 'NULL' }
$odsDbNameSqlLit = $resolvedOdsDbName.Replace("'", "''")

Write-Host "  Environment '$resolvedEnvName' (id $sbEnvironmentId), tenant id $tenantId, ODS '$resolvedOdsDbName' (id $odsId, odsInstanceId $(if ($null -ne $odsInstanceId) { $odsInstanceId } else { 'NULL' }))."

# ---- Step 3: build and run the load ------------------------------------------
# The CSV rows are staged into a temp table, then everything happens set-based
# in one transaction: insert missing edorg rows, wire parentId within the
# scope, and fill in the edorg_closure ancestor/self pairs the Admin App's
# tree queries expect (the closure insert covers pre-existing rows too, so a
# partially-synced scope is healed rather than corrupted).
function Get-StageValuesBatches
{
    # Multi-row VALUES batches (SQL Server caps a VALUES list at 1000 rows).
    # LiteralPrefix is 'N' on SQL Server: without it the strings are non-Unicode
    # literals and get converted to the database's code page before landing in
    # the nvarchar columns, silently turning characters the code page cannot
    # represent into '?'. PostgreSQL literals are already Unicode; no prefix.
    param([string]$NullKeyword = 'NULL', [string]$LiteralPrefix = '')
    $batchSize = 500
    $batches = @()
    for ($i = 0; $i -lt $rows.Count; $i += $batchSize)
    {
        $values = foreach ($row in $rows[$i..([Math]::Min($i + $batchSize, $rows.Count) - 1)])
        {
            $name = $row.Name.Replace("'", "''")
            $short = if ($row.ShortName) { "$LiteralPrefix'" + $row.ShortName.Replace("'", "''") + "'" } else { $NullKeyword }
            $disc = $row.Discriminator.Replace("'", "''")
            $parent = if ($null -ne $row.ParentEdOrgId) { $row.ParentEdOrgId } else { $NullKeyword }
            "($($row.EdOrgId), $LiteralPrefix'$name', $short, $LiteralPrefix'$disc', $parent)"
        }
        $batches += ($values -join ",`n")
    }
    return $batches
}

if ($DbEngine -eq 'mssql')
{
    $stageInserts = (Get-StageValuesBatches -LiteralPrefix 'N' | ForEach-Object {
            "INSERT INTO #stage (edOrgId, name, shortName, disc, parentEdOrgId) VALUES`n$_;"
        }) -join "`n"

    $sql = @"
SET QUOTED_IDENTIFIER ON;
SET XACT_ABORT ON;
SET NOCOUNT ON;

CREATE TABLE #stage (
    edOrgId bigint NOT NULL PRIMARY KEY,
    name nvarchar(255) NOT NULL,
    shortName nvarchar(255) NULL,
    disc nvarchar(255) NOT NULL,
    parentEdOrgId bigint NULL
);
$stageInserts

BEGIN TRANSACTION;

-- Ids not in the scope yet, recorded before the insert: the run reports (and
-- the manifest records) exactly what it created, as opposed to rows that
-- already existed.
SELECT s.edOrgId INTO #new
FROM #stage s
WHERE NOT EXISTS (SELECT 1 FROM [edorg] e
                  WHERE e.[edfiTenantId] = $tenantId AND e.[odsId] = $odsId
                      AND e.[educationOrganizationId] = s.edOrgId);

INSERT INTO [edorg] ([created], [modified], [odsId], [odsDbName], [odsInstanceId],
                     [edfiTenantId], [sbEnvironmentId], [educationOrganizationId],
                     [nameOfInstitution], [shortNameOfInstitution], [discriminator])
SELECT GETDATE(), GETDATE(), $odsId, N'$odsDbNameSqlLit', $odsInstanceIdSql,
       $tenantId, $sbEnvironmentId, s.edOrgId,
       s.name, s.shortName, s.disc
FROM #stage s
WHERE s.edOrgId IN (SELECT edOrgId FROM #new);
PRINT CONCAT('Inserted ', @@ROWCOUNT, ' new edorg row(s).');

-- Existing rows whose name or type differs are corrected -- the same three
-- columns the Admin App's own sync maintains (packages/api sync-ods.ts). In
-- particular this fixes the 'Institution #<id>' / edfi.Other placeholder rows
-- the Admin App writes when an ODS is registered with allowed ed orgs.
UPDATE e SET [nameOfInstitution] = s.name,
             [shortNameOfInstitution] = s.shortName,
             [discriminator] = s.disc,
             [modified] = GETDATE()
FROM [edorg] e
    INNER JOIN #stage s ON s.edOrgId = e.[educationOrganizationId]
WHERE e.[edfiTenantId] = $tenantId AND e.[odsId] = $odsId
    AND (e.[nameOfInstitution] <> s.name
         OR COALESCE(e.[shortNameOfInstitution], N'') <> COALESCE(s.shortName, N'')
         OR e.[discriminator] <> s.disc);
PRINT CONCAT('Updated ', @@ROWCOUNT, ' existing row(s) whose name or type differed from the CSV.');

-- Wire the hierarchy. Only rows without a parent are touched, so links
-- written by the Admin App itself are never clobbered.
UPDATE e SET [parentId] = p.[id]
FROM [edorg] e
    INNER JOIN #stage s ON s.edOrgId = e.[educationOrganizationId]
    INNER JOIN [edorg] p ON p.[edfiTenantId] = $tenantId AND p.[odsId] = $odsId
        AND p.[educationOrganizationId] = s.parentEdOrgId
WHERE e.[edfiTenantId] = $tenantId AND e.[odsId] = $odsId
    AND e.[parentId] IS NULL;
PRINT CONCAT('Linked ', @@ROWCOUNT, ' row(s) to their parent.');

-- Closure pairs (self + every ancestor), same shape the Admin App's ORM
-- writes. Recomputed for the whole scope and inserted where missing. The
-- missing pairs are staged first: the closure table's INSTEAD OF trigger
-- (TR_edorg_closure_psuedo_fk) raises its FK error on an EMPTY insert set,
-- so the insert must only run when there is something to insert.
WITH chain AS (
    SELECT e.[id] AS descendant, e.[id] AS ancestor
    FROM [edorg] e
    WHERE e.[edfiTenantId] = $tenantId AND e.[odsId] = $odsId
    UNION ALL
    SELECT c.descendant, e.[parentId]
    FROM chain c
        INNER JOIN [edorg] e ON e.[id] = c.ancestor
    WHERE e.[parentId] IS NOT NULL
)
SELECT c.ancestor, c.descendant
INTO #closure_missing
FROM chain c
WHERE NOT EXISTS (SELECT 1 FROM [edorg_closure] cc
                  WHERE cc.[id_ancestor] = c.ancestor AND cc.[id_descendant] = c.descendant);

IF EXISTS (SELECT 1 FROM #closure_missing)
BEGIN
    INSERT INTO [edorg_closure] ([id_ancestor], [id_descendant])
    SELECT ancestor, descendant FROM #closure_missing;
END

COMMIT TRANSACTION;

SELECT CONCAT('INSERTED|', edOrgId) FROM #new ORDER BY edOrgId;
SELECT CONCAT('TOTAL|', COUNT(*)) FROM [edorg]
WHERE [edfiTenantId] = $tenantId AND [odsId] = $odsId;
"@
}
else
{
    $stageInserts = (Get-StageValuesBatches | ForEach-Object {
            "INSERT INTO stage (edorgid, name, shortname, disc, parentedorgid) VALUES`n$_;"
        }) -join "`n"

    $sql = @"
BEGIN;

CREATE TEMP TABLE stage (
    edorgid bigint NOT NULL PRIMARY KEY,
    name varchar NOT NULL,
    shortname varchar NULL,
    disc varchar NOT NULL,
    parentedorgid bigint NULL
) ON COMMIT DROP;
$stageInserts

-- Ids not in the scope yet, recorded before the insert: the run reports (and
-- the manifest records) exactly what it created, as opposed to rows that
-- already existed.
CREATE TEMP TABLE new_ids ON COMMIT DROP AS
SELECT s.edorgid
FROM stage s
WHERE NOT EXISTS (SELECT 1 FROM edorg e
                  WHERE e."edfiTenantId" = $tenantId AND e."odsId" = $odsId
                      AND e."educationOrganizationId" = s.edorgid);

INSERT INTO edorg (created, modified, "odsId", "odsDbName", "odsInstanceId",
                   "edfiTenantId", "sbEnvironmentId", "educationOrganizationId",
                   "nameOfInstitution", "shortNameOfInstitution", discriminator)
SELECT now(), now(), $odsId, '$odsDbNameSqlLit', $odsInstanceIdSql,
       $tenantId, $sbEnvironmentId, s.edorgid,
       s.name, s.shortname, s.disc
FROM stage s
WHERE s.edorgid IN (SELECT edorgid FROM new_ids)
ON CONFLICT ("edfiTenantId", "odsId", "educationOrganizationId") DO NOTHING;
SELECT CONCAT('MSG|Inserted ', COUNT(*), ' new edorg row(s).') FROM new_ids;

-- Existing rows whose name or type differs are corrected -- the same three
-- columns the Admin App's own sync maintains (packages/api sync-ods.ts). In
-- particular this fixes the 'Institution #<id>' / edfi.Other placeholder rows
-- the Admin App writes when an ODS is registered with allowed ed orgs.
CREATE TEMP TABLE changed_ids ON COMMIT DROP AS
SELECT s.edorgid
FROM stage s
    JOIN edorg e ON e."edfiTenantId" = $tenantId AND e."odsId" = $odsId
        AND e."educationOrganizationId" = s.edorgid
WHERE (e."nameOfInstitution", e."shortNameOfInstitution", e.discriminator)
      IS DISTINCT FROM (s.name, s.shortname, s.disc);

UPDATE edorg e SET "nameOfInstitution" = s.name,
                   "shortNameOfInstitution" = s.shortname,
                   discriminator = s.disc,
                   modified = now()
FROM stage s
WHERE e."edfiTenantId" = $tenantId AND e."odsId" = $odsId
    AND e."educationOrganizationId" = s.edorgid
    AND s.edorgid IN (SELECT edorgid FROM changed_ids);
SELECT CONCAT('MSG|Updated ', COUNT(*), ' existing row(s) whose name or type differed from the CSV.') FROM changed_ids;

-- Wire the hierarchy. Only rows without a parent are touched, so links
-- written by the Admin App itself are never clobbered.
UPDATE edorg e SET "parentId" = p.id
FROM stage s
    JOIN edorg p ON p."edfiTenantId" = $tenantId AND p."odsId" = $odsId
        AND p."educationOrganizationId" = s.parentedorgid
WHERE e."educationOrganizationId" = s.edorgid
    AND e."edfiTenantId" = $tenantId AND e."odsId" = $odsId
    AND e."parentId" IS NULL;

-- Closure pairs (self + every ancestor), same shape the Admin App's ORM
-- writes. Recomputed for the whole scope and inserted where missing.
WITH RECURSIVE chain AS (
    SELECT e.id AS descendant, e.id AS ancestor
    FROM edorg e
    WHERE e."edfiTenantId" = $tenantId AND e."odsId" = $odsId
    UNION ALL
    SELECT c.descendant, e."parentId"
    FROM chain c
        JOIN edorg e ON e.id = c.ancestor
    WHERE e."parentId" IS NOT NULL
)
INSERT INTO edorg_closure (id_ancestor, id_descendant)
SELECT ancestor, descendant FROM chain
ON CONFLICT (id_ancestor, id_descendant) DO NOTHING;

-- Emitted before COMMIT: the temp tables are ON COMMIT DROP.
SELECT CONCAT('INSERTED|', edorgid) FROM new_ids ORDER BY edorgid;

COMMIT;

SELECT CONCAT('TOTAL|', COUNT(*)) FROM edorg
WHERE "edfiTenantId" = $tenantId AND "odsId" = $odsId;
"@
}

Write-Host "`nImporting into edorg (tenant $tenantId, ods $odsId)..."
$output = Invoke-AdminAppSql -Sql $sql -FailHint 'Nothing was imported (the load is transactional).'
# Filter out psql command tags ('INSERT 0 5', 'COMMIT', ...) and the
# machine-readable INSERTED|/TOTAL| rows, but keep the PRINT/MSG| messages.
$output | Where-Object {
    "$_".Trim() -and "$_" -notmatch '^(TOTAL|INSERTED)\|' -and
    "$_" -notmatch '^(INSERT 0 \d+$|UPDATE \d+$|BEGIN$|COMMIT$|CREATE TABLE$|SELECT \d+$)'
} | ForEach-Object { Write-Host "  $("$_" -replace '^MSG\|', '')" }
$total = ($output | Where-Object { "$_" -match '^TOTAL\|' } | Select-Object -First 1) -replace '^TOTAL\|', ''

# Manifest of the rows this run actually INSERTED (never the pre-existing
# ones), keyed by scope. cleanup-edorgs.ps1 deletes only ids recorded here, so
# rows the Admin App created itself -- e.g. the 'Institution #<id>' placeholders
# from an ODS registration -- are never cleanup victims. Merged with any
# existing manifest so multi-CSV imports accumulate.
$insertedIds = @($output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^INSERTED\|\d+$' } |
        ForEach-Object { [long]($_ -replace '^INSERTED\|', '') })
$manifestPath = Join-Path (Split-Path -Parent (Resolve-Path $CsvPath)) 'imported-ids.csv'
if ($insertedIds.Count -gt 0)
{
    $manifestRows = @(if (Test-Path $manifestPath) { Import-Csv -Path $manifestPath -Encoding UTF8 })
    $manifestKeys = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
            $manifestRows | ForEach-Object { "$($_.tenantId)/$($_.odsId)/$($_.educationOrganizationId)" }))
    $newManifestRows = @($insertedIds | Where-Object { -not $manifestKeys.Contains("$tenantId/$odsId/$_") } |
            ForEach-Object { [pscustomobject]@{ educationOrganizationId = $_; tenantId = $tenantId; odsId = $odsId } })
    if ($newManifestRows.Count -gt 0)
    {
        @($manifestRows) + $newManifestRows | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding utf8
    }
    Write-Host "  Recorded the $($insertedIds.Count) inserted id(s) in $manifestPath (cleanup-edorgs.ps1 deletes only ids recorded there)."
}

Write-Host "`nSUCCESS: $($rows.Count) education organizations imported or updated ($total total in the scope)." -ForegroundColor Green
Write-Host "Next:" -ForegroundColor Green
Write-Host "  1. In the Admin App, create (or edit) an Application: the imported ed orgs"
Write-Host "     now appear in the Education Organization dropdown for ODS '$resolvedOdsDbName'."
Write-Host "  2. Non-admin teams see them only once they are granted ownership of the"
Write-Host "     tenant, environment, ODS, or individual ed orgs (Admin App > team access)."
Write-Host "  3. This import is a one-time bridge: Admin App v4.1 is slated to keep ed"
Write-Host "     orgs in sync natively, after which re-running it is unnecessary."
