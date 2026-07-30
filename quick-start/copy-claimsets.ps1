<#
.SYNOPSIS
  Copy built-in Ed-Fi claimsets in the EdFi_Security database under an "AA "
  prefix (e.g. 'SIS Vendor' -> 'AA SIS Vendor') so they can be assigned to
  applications in the Admin App. Idempotent.

.DESCRIPTION
  The Admin App hides built-in (IsEdfiPreset) claimsets from the application
  claimset dropdown, so a key/secret cannot be created against them directly --
  the claimset must first be copied under a new name. This script performs that
  copy in SQL, directly against the EdFi_Security database.

  By default (no -ClaimSetNames) it copies EVERY built-in claimset
  (IsEdfiPreset = 1), excluding internal-use ones (ForApplicationUseOnly = 1,
  e.g. 'Bootstrap Descriptors and EdOrgs'); pass -ClaimSetNames to copy a
  specific list instead (including, if wanted, an internal-use one). For each
  claimset it:

    * inserts a new row into dbo.ClaimSets named '<Prefix><name>' with
      IsEdfiPreset = 0 and ForApplicationUseOnly = 0 (same as the Admin API's
      "copy claimset" feature),
    * copies every dbo.ClaimSetResourceClaimActions row of the source, and
    * copies every dbo.ClaimSetResourceClaimActionAuthorizationStrategyOverrides
      row, remapped to the new action rows.

  Each claimset is copied in its own transaction. If the target name already
  exists the claimset is skipped (re-runs are no-ops and never clobber edits
  made to a copy through the Admin App). A missing SOURCE claimset is a hard
  error, to protect against typos.

  NOTE: on PostgreSQL, claimset name matching is case-sensitive; pass names
  exactly as they appear in dbo.ClaimSets (the defaults already do).

.EXAMPLE
  # SQL Server (default engine), local EdFi_Security. EdFi_Security lives on
  # the ODS/API side, so it has its own login -- pass one with rights on that
  # database ('sa' is deliberately not the default), or use
  # -UseIntegratedSecurity instead.
  ./copy-claimsets.ps1 -SqlUser 'edfi_security_user' -SqlPassword 'EdFi-Sec!2026'

.EXAMPLE
  # SQL Server on the ODS/API host:
  ./copy-claimsets.ps1 -SqlServer 'tcp:ods-db.example.org,1433' `
    -SqlUser 'edfi_security_user' -SqlPassword '...'

.EXAMPLE
  # SQL Server with Windows integrated authentication (e.g. a local initdev
  # environment):
  ./copy-claimsets.ps1 -SqlServer 'localhost' -UseIntegratedSecurity

.EXAMPLE
  # PostgreSQL:
  ./copy-claimsets.ps1 -DbEngine pgsql -PostgresPassword 'P@ssw0rd'

.EXAMPLE
  # PostgreSQL running in the ODS Docker stack:
  ./copy-claimsets.ps1 -DbEngine pgsql -PostgresPassword 'P@ssw0rd' -UsePostgresDocker

.EXAMPLE
  # Copy only specific claimsets, or use a different prefix:
  ./copy-claimsets.ps1 -SqlUser 'edfi_security_user' -SqlPassword '...' `
    -ClaimSetNames 'SIS Vendor', 'Ed-Fi Sandbox', 'Assessment Vendor' -Prefix 'AA '
#>
#requires -Version 5.1
param(
    # Claimsets to copy. Empty (the default) = all built-in claimsets
    # (IsEdfiPreset = 1, excluding ForApplicationUseOnly = 1).
    [string[]]$ClaimSetNames = @(),
    # Prefix for the copies (trailing space intentional): 'SIS Vendor' -> 'AA SIS Vendor'.
    [string]$Prefix = 'AA ',

    [ValidateSet('mssql', 'pgsql')][string]$DbEngine = 'mssql',
    [string]$DatabaseName = 'EdFi_Security',

    # --- mssql -----------------------------------------------------------------
    # EdFi_Security is provisioned by the ODS/API installation, so it may not be
    # on this machine -- server and login are parameterized. It is a different
    # database from the Admin App's, so it needs its own login with rights on
    # EdFi_Security ('sa' is deliberately not the default, EDFI-2776); or use
    # -UseIntegratedSecurity for Windows authentication.
    [string]$SqlServer = 'tcp:localhost,1433',
    [string]$SqlUser,                            # required for -DbEngine mssql unless -UseIntegratedSecurity
    [string]$SqlPassword,                        # required for -DbEngine mssql unless -UseIntegratedSecurity
    [switch]$UseIntegratedSecurity,

    # --- pgsql -----------------------------------------------------------------
    [string]$PostgresPassword,                   # required for -DbEngine pgsql
    [string]$PostgresHost = 'localhost',
    [int]$PostgresPort = 5432,
    [string]$PostgresUser = 'postgres',
    [switch]$UsePostgresDocker,
    # The ODS Docker stack's admin/security database container.
    [string]$PostgresContainerName = 'ed-fi-db-admin'
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/compat.ps1"

# Engine-specific required-arg validation.
if ($DbEngine -eq 'mssql' -and -not $UseIntegratedSecurity -and (-not $SqlUser -or -not $SqlPassword)) { throw "-SqlUser and -SqlPassword (a login with rights on EdFi_Security) are required when -DbEngine is 'mssql' (the default) without -UseIntegratedSecurity." }
if ($UseIntegratedSecurity -and $DbEngine -ne 'mssql') { throw "-UseIntegratedSecurity only applies when -DbEngine is 'mssql'." }
if ($DbEngine -eq 'pgsql' -and -not $PostgresPassword) { throw "-PostgresPassword is required when -DbEngine is 'pgsql'." }
if ($UsePostgresDocker -and $DbEngine -ne 'pgsql') { throw "-UsePostgresDocker only applies when -DbEngine is 'pgsql'." }

if ($DbEngine -eq 'mssql')
{
    # The @(...) wrap is load-bearing: assignment from an if-expression unrolls
    # a one-element array to a scalar string, and splatting a scalar to a
    # native command garbles the argument list.
    $authArgs = @(if ($UseIntegratedSecurity) { '-E' } else { '-U', $SqlUser, '-P', $SqlPassword })
}

# No -ClaimSetNames: discover every built-in claimset, excluding internal-use
# ones (ForApplicationUseOnly = 1, e.g. 'Bootstrap Descriptors and EdOrgs').
if ($ClaimSetNames.Count -eq 0)
{
    Write-Host "Discovering built-in claimsets in $DbEngine db '$DatabaseName'..."
    if ($DbEngine -eq 'mssql')
    {
        $listSql = 'SET NOCOUNT ON; SELECT ClaimSetName FROM dbo.ClaimSets WHERE IsEdfiPreset = 1 AND ForApplicationUseOnly = 0 ORDER BY ClaimSetId;'
        $raw = & sqlcmd -S $SqlServer @authArgs -d $DatabaseName -C -b -h -1 -W -Q $listSql
        if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed listing claimsets (exit $LASTEXITCODE). Check -SqlServer / -SqlUser / -SqlPassword / -DatabaseName." }
    }
    else
    {
        $listSql = 'SELECT claimsetname FROM dbo.claimsets WHERE isedfipreset = TRUE AND forapplicationuseonly = FALSE ORDER BY claimsetid;'
        if ($UsePostgresDocker)
        {
            $raw = $listSql | & docker exec -i -e "PGPASSWORD=$PostgresPassword" $PostgresContainerName psql -U $PostgresUser -d $DatabaseName -v ON_ERROR_STOP=1 -t -A
        }
        else
        {
            $env:PGPASSWORD = $PostgresPassword
            $raw = $listSql | & psql -h $PostgresHost -p $PostgresPort -U $PostgresUser -d $DatabaseName -v ON_ERROR_STOP=1 -t -A
        }
        if ($LASTEXITCODE -ne 0) { throw "psql failed listing claimsets (exit $LASTEXITCODE). Check -PostgresPassword / -PostgresHost / -PostgresPort / -PostgresUser / -DatabaseName." }
    }
    $ClaimSetNames = @($raw | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if ($ClaimSetNames.Count -eq 0) { throw "No built-in claimsets found in '$DatabaseName'." }
    Write-Host "  Found $($ClaimSetNames.Count): $($ClaimSetNames -join ', ')"
}

$copies = @()
foreach ($name in $ClaimSetNames)
{
    $targetDisplay = "$Prefix$name"
    # Escape for use inside SQL string literals.
    $sourceName = $name.Replace("'", "''")
    $targetName = $targetDisplay.Replace("'", "''")

    Write-Host "`nCopying claimset '$name' -> '$targetDisplay' in $DbEngine db '$DatabaseName'..."

    if ($DbEngine -eq 'mssql')
    {
        # The old->new ClaimSetResourceClaimActionId mapping for the overrides
        # table rides on the (ClaimSetId, ResourceClaimId, ActionId) unique key:
        # each source action row is joined to its just-inserted twin.
        $sql = @"
SET QUOTED_IDENTIFIER ON;
SET XACT_ABORT ON;

DECLARE @sourceName nvarchar(255) = N'$sourceName';
DECLARE @targetName nvarchar(255) = N'$targetName';
DECLARE @sourceId int = (SELECT ClaimSetId FROM dbo.ClaimSets WHERE ClaimSetName = @sourceName);

IF @sourceId IS NULL
BEGIN
    -- No double quotes in messages: this batch is passed to sqlcmd -Q as a
    -- command-line argument and embedded quotes break argument parsing.
    DECLARE @msg nvarchar(400) = N'Source claimset ''' + @sourceName + N''' not found in dbo.ClaimSets.';
    THROW 50001, @msg, 1;
END

IF EXISTS (SELECT 1 FROM dbo.ClaimSets WHERE ClaimSetName = @targetName)
    PRINT 'Claimset ''' + @targetName + ''' already exists; skipping.';
ELSE
BEGIN
    BEGIN TRANSACTION;

    INSERT INTO dbo.ClaimSets (ClaimSetName, IsEdfiPreset, ForApplicationUseOnly)
    VALUES (@targetName, 0, 0);
    DECLARE @targetId int = SCOPE_IDENTITY();

    INSERT INTO dbo.ClaimSetResourceClaimActions
        (ClaimSetId, ResourceClaimId, ActionId, ValidationRuleSetNameOverride)
    SELECT @targetId, ResourceClaimId, ActionId, ValidationRuleSetNameOverride
    FROM dbo.ClaimSetResourceClaimActions
    WHERE ClaimSetId = @sourceId;

    INSERT INTO dbo.ClaimSetResourceClaimActionAuthorizationStrategyOverrides
        (ClaimSetResourceClaimActionId, AuthorizationStrategyId)
    SELECT tgt.ClaimSetResourceClaimActionId, ov.AuthorizationStrategyId
    FROM dbo.ClaimSetResourceClaimActions src
        INNER JOIN dbo.ClaimSetResourceClaimActionAuthorizationStrategyOverrides ov
            ON ov.ClaimSetResourceClaimActionId = src.ClaimSetResourceClaimActionId
        INNER JOIN dbo.ClaimSetResourceClaimActions tgt
            ON tgt.ClaimSetId = @targetId
           AND tgt.ResourceClaimId = src.ResourceClaimId
           AND tgt.ActionId = src.ActionId
    WHERE src.ClaimSetId = @sourceId;

    COMMIT TRANSACTION;
    PRINT 'Created claimset ''' + @targetName + '''.';
END
"@
        # -b makes sqlcmd exit nonzero on SQL errors; without it $LASTEXITCODE
        # stays 0 and failures would pass silently.
        & sqlcmd -S $SqlServer @authArgs -d $DatabaseName -C -b -Q $sql
        if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed for claimset '$name' (exit $LASTEXITCODE). Check -SqlServer / -SqlUser / -SqlPassword / -DatabaseName." }
    }
    else
    {
        # A DO block is a single statement, so the whole copy is atomic; RAISE
        # EXCEPTION aborts with a nonzero exit thanks to ON_ERROR_STOP.
        $sql = @"
DO `$`$
DECLARE
    source_name text := '$sourceName';
    target_name text := '$targetName';
    source_id int;
    target_id int;
BEGIN
    SELECT claimsetid INTO source_id FROM dbo.claimsets WHERE claimsetname = source_name;
    IF source_id IS NULL THEN
        RAISE EXCEPTION 'Source claimset "%" not found in dbo.claimsets.', source_name;
    END IF;

    IF EXISTS (SELECT 1 FROM dbo.claimsets WHERE claimsetname = target_name) THEN
        RAISE NOTICE 'Claimset "%" already exists; skipping.', target_name;
        RETURN;
    END IF;

    INSERT INTO dbo.claimsets (claimsetname, isedfipreset, forapplicationuseonly)
    VALUES (target_name, FALSE, FALSE)
    RETURNING claimsetid INTO target_id;

    INSERT INTO dbo.claimsetresourceclaimactions
        (claimsetid, resourceclaimid, actionid, validationrulesetnameoverride)
    SELECT target_id, resourceclaimid, actionid, validationrulesetnameoverride
    FROM dbo.claimsetresourceclaimactions
    WHERE claimsetid = source_id;

    INSERT INTO dbo.claimsetresourceclaimactionauthorizationstrategyoverrides
        (claimsetresourceclaimactionid, authorizationstrategyid)
    SELECT tgt.claimsetresourceclaimactionid, ov.authorizationstrategyid
    FROM dbo.claimsetresourceclaimactions src
        JOIN dbo.claimsetresourceclaimactionauthorizationstrategyoverrides ov
            ON ov.claimsetresourceclaimactionid = src.claimsetresourceclaimactionid
        JOIN dbo.claimsetresourceclaimactions tgt
            ON tgt.claimsetid = target_id
           AND tgt.resourceclaimid = src.resourceclaimid
           AND tgt.actionid = src.actionid
    WHERE src.claimsetid = source_id;

    RAISE NOTICE 'Created claimset "%".', target_name;
END
`$`$;
"@
        if ($UsePostgresDocker)
        {
            $sql | & docker exec -i -e "PGPASSWORD=$PostgresPassword" $PostgresContainerName psql -U $PostgresUser -d $DatabaseName -v ON_ERROR_STOP=1
        }
        else
        {
            $env:PGPASSWORD = $PostgresPassword
            $sql | & psql -h $PostgresHost -p $PostgresPort -U $PostgresUser -d $DatabaseName -v ON_ERROR_STOP=1
        }
        if ($LASTEXITCODE -ne 0) { throw "psql failed for claimset '$name' (exit $LASTEXITCODE). Check -PostgresPassword / -PostgresHost / -PostgresPort / -PostgresUser / -DatabaseName." }
    }

    $copies += $targetDisplay
}

Write-Host "`nSUCCESS: claimset copies ready." -ForegroundColor Green
Write-Host "Next:" -ForegroundColor Green
Write-Host "  1. In the Admin App, create (or edit) an application and select one of:"
foreach ($copy in $copies) { Write-Host "       - $copy" }
Write-Host "  2. Use the generated key/secret to call the ODS/API."
