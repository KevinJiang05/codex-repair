[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$guiScript = Join-Path $projectRoot 'scripts\repair-gui.ps1'
$repairScript = Join-Path $projectRoot 'scripts\repair-core.ps1'
$batchRepairScript = Join-Path $projectRoot 'scripts\repair-batch.ps1'
$restoreScript = Join-Path $projectRoot 'scripts\restore-core.ps1'
$pythonCommand = Get-Command py -ErrorAction SilentlyContinue
$pythonArguments = @('-3')
if (-not $pythonCommand) {
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    $pythonArguments = @()
}
if (-not $pythonCommand) {
    throw 'Python 3 is required for the smoke test.'
}
$pythonBootstrap = 'import base64,sys;exec(base64.b64decode(sys.argv.pop(1)))'

function Invoke-TestPython {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [string[]]$Arguments = @()
    )

    $encodedCode = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Code))
    & $pythonCommand.Source @pythonArguments -c $pythonBootstrap $encodedCode @Arguments
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-Refused {
    param([scriptblock]$Action, [string]$Message)
    $refused = $false
    try { & $Action | Out-Null }
    catch { $refused = $true }
    Assert-Equal $refused $true $Message
}

function Write-TestSession {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [string]$RuntimeProvider
    )

    $records = [Collections.Generic.List[string]]::new()
    $records.Add((@{
        type = 'session_meta'
        payload = @{
            id = $SessionId
            model_provider = 'custom'
        }
    } | ConvertTo-Json -Depth 5 -Compress))
    if ($RuntimeProvider) {
        $records.Add((@{
            type = 'event_msg'
            payload = @{
                type = 'thread_settings_applied'
                thread_settings = @{
                    model_provider_id = $RuntimeProvider
                }
            }
        } | ConvertTo-Json -Depth 5 -Compress))
    }
    [IO.File]::WriteAllText(
        $Path,
        (($records -join "`n") + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

$temporaryBase = [IO.Path]::GetFullPath((Join-Path $projectRoot '.tmp'))
$null = New-Item -ItemType Directory -Path $temporaryBase -Force
$testRoot = Join-Path $temporaryBase ("codex-repair-smoke-" + [guid]::NewGuid().ToString('N'))
$safeId1 = '11111111-1111-4111-8111-111111111111'
$safeId2 = '22222222-2222-4222-8222-222222222222'
$conflictId = '33333333-3333-4333-8333-333333333333'

try {
    $codexHome = Join-Path $testRoot '.codex'
    $sessionsDirectory = Join-Path $codexHome 'sessions\2026\09\15'
    $backupRoot = Join-Path $testRoot 'backups'
    $batchDirectory = Join-Path $backupRoot 'test-batch'
    $null = New-Item -ItemType Directory -Path $sessionsDirectory -Force
    $null = New-Item -ItemType Directory -Path $batchDirectory -Force

    [IO.File]::WriteAllText(
        (Join-Path $codexHome 'config.toml'),
        "model_provider = `"openai`" # fixture comment`n[profiles.demo]`nmodel_provider = `"nested-only`"`n",
        [Text.UTF8Encoding]::new($false)
    )

    $sessionPaths = @{}
    foreach ($id in @($safeId1, $safeId2, $conflictId)) {
        $sessionPaths[$id] = Join-Path $sessionsDirectory "rollout-2026-09-15T00-00-00-$id.jsonl"
    }
    Write-TestSession -Path $sessionPaths[$safeId1] -SessionId $safeId1 -RuntimeProvider 'openai'
    Write-TestSession -Path $sessionPaths[$safeId2] -SessionId $safeId2
    Write-TestSession -Path $sessionPaths[$conflictId] -SessionId $conflictId -RuntimeProvider 'custom'

    $fixedTime = [datetime]::SpecifyKind(
        [datetime]'2026-01-02T03:04:05',
        [DateTimeKind]::Utc
    )
    foreach ($path in $sessionPaths.Values) {
        (Get-Item -LiteralPath $path).LastWriteTimeUtc = $fixedTime
    }

    $databasePath = Join-Path $codexHome 'state_5.sqlite'
    $databaseSetup = @'
import sqlite3
import sys

database = sys.argv[1]
rows = []
for index in range(2, len(sys.argv), 2):
    rows.append((sys.argv[index], sys.argv[index + 1], 1_789_430_400, "custom", "fixture", 0))
with sqlite3.connect(database) as connection:
    connection.execute(
        "create table threads (id text primary key, rollout_path text, created_at integer, "
        "model_provider text, title text, archived integer)"
    )
    connection.executemany(
        "insert into threads values (?, ?, ?, ?, ?, ?)",
        rows,
    )
'@
    Invoke-TestPython -Code $databaseSetup -Arguments @(
        $databasePath,
        $safeId1, $sessionPaths[$safeId1],
        $safeId2, $sessionPaths[$safeId2],
        $conflictId, $sessionPaths[$conflictId]
    )
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not create the smoke-test state database.'
    }

    $scanSummary = @(& $guiScript -ScanOnly -AllDates -SummaryOnly -CodexHome $codexHome)
    if (($scanSummary -join "`n") -notmatch
        'Scanned: 3; needs repair: 3; standard: 2; advanced: 1; blocked: 0; target provider: openai') {
        throw "The GUI scanner returned unexpected classifications: $($scanSummary -join ' ')"
    }

    $beforeFailure = (Get-FileHash -LiteralPath $sessionPaths[$safeId1]).Hash
    $databaseBeforeFailure = (Get-FileHash -LiteralPath $databasePath).Hash
    $badBatch = Join-Path $backupRoot 'unwritable-manifest'
    $null = New-Item -ItemType Directory -Path (Join-Path $badBatch "sessions\$safeId1\manifest.json") -Force
    Assert-Refused {
        & $repairScript -SessionId $safeId1 -CodexHome $codexHome -BackupRoot $backupRoot -BatchBackupDirectory $badBatch
    } 'An unwritable manifest must refuse repair.'
    Assert-Equal (Get-FileHash -LiteralPath $sessionPaths[$safeId1]).Hash $beforeFailure 'Manifest failure changed JSONL.'
    Assert-Equal (Get-FileHash -LiteralPath $databasePath).Hash $databaseBeforeFailure 'Manifest failure changed SQLite.'

    $writer = [IO.FileStream]::new($sessionPaths[$safeId1], [IO.FileMode]::Append, [IO.FileAccess]::Write, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        Assert-Refused {
            & $repairScript -SessionId $safeId1 -CodexHome $codexHome -BackupRoot $backupRoot -BatchBackupDirectory $batchDirectory
        } 'An open writer must refuse repair.'
    }
    finally { $writer.Dispose() }
    Assert-Equal (Get-FileHash -LiteralPath $sessionPaths[$safeId1]).Hash $beforeFailure 'Busy-file refusal changed JSONL.'
    Assert-Equal (Get-FileHash -LiteralPath $databasePath).Hash $databaseBeforeFailure 'Busy-file refusal changed SQLite.'

    . (Join-Path $projectRoot 'scripts\session-io.ps1')
    $staleBytes = [IO.File]::ReadAllBytes($sessionPaths[$safeId1])
    [IO.File]::AppendAllText($sessionPaths[$safeId1], "{`"type`":`"event_msg`",`"payload`":{`"type`":`"concurrent_append_fixture`"}}`n")
    $appendedHash = (Get-FileHash -LiteralPath $sessionPaths[$safeId1]).Hash
    Assert-Refused {
        $guard = Open-SessionWriteGuard -Path $sessionPaths[$safeId1] -ExpectedBytes $staleBytes
        $guard.Dispose()
    } 'A stale JSONL snapshot must refuse writing.'
    Assert-Equal (Get-FileHash -LiteralPath $sessionPaths[$safeId1]).Hash $appendedHash 'Stale-snapshot refusal lost appended content.'
    (Get-Item -LiteralPath $sessionPaths[$safeId1]).LastWriteTimeUtc = $fixedTime

    foreach ($id in @($safeId1, $safeId2)) {
        & $repairScript -SessionId $id -CodexHome $codexHome `
            -BackupRoot $backupRoot -BatchBackupDirectory $batchDirectory |
            Out-Null
    }

    $databaseBackup = Join-Path $batchDirectory 'state_5.sqlite.bak'
    Assert-Equal (Test-Path -LiteralPath $databaseBackup -PathType Leaf) $true `
        'The batch database backup was not created.'
    Assert-Equal @(Get-ChildItem -LiteralPath $batchDirectory -Filter '*.sqlite.bak' -File).Count 1 `
        'A batch must contain exactly one state database snapshot.'

    foreach ($id in @($safeId1, $safeId2)) {
        $first = [IO.File]::ReadLines($sessionPaths[$id]) | Select-Object -First 1
        $provider = ($first | ConvertFrom-Json).payload.model_provider
        Assert-Equal $provider 'openai' "The JSONL provider was not repaired for $id."
        Assert-Equal (Get-Item -LiteralPath $sessionPaths[$id]).LastWriteTimeUtc $fixedTime `
            "The JSONL timestamp changed for $id."
        Assert-Equal (
            Test-Path -LiteralPath (Join-Path $batchDirectory "sessions\$id\manifest.json") -PathType Leaf
        ) $true "The repair manifest is missing for $id."
    }

    $databaseCheck = @'
import json
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    values = dict(connection.execute("select id, model_provider from threads"))
print(json.dumps(values))
'@
    $liveProviders = (Invoke-TestPython -Code $databaseCheck -Arguments @($databasePath)) |
        ConvertFrom-Json
    Assert-Equal $liveProviders.PSObject.Properties[$safeId1].Value 'openai' 'The first database row was not repaired.'
    Assert-Equal $liveProviders.PSObject.Properties[$safeId2].Value 'openai' 'The second database row was not repaired.'
    Assert-Equal $liveProviders.PSObject.Properties[$conflictId].Value 'custom' 'The conflict database row changed unexpectedly.'

    $backupProviders = (Invoke-TestPython -Code $databaseCheck -Arguments @($databaseBackup)) |
        ConvertFrom-Json
    Assert-Equal $backupProviders.PSObject.Properties[$safeId1].Value 'custom' 'The database snapshot is not a pre-batch backup.'
    Assert-Equal $backupProviders.PSObject.Properties[$safeId2].Value 'custom' 'The shared database snapshot changed during the batch.'

    $conflictBlocked = $false
    try {
        & $repairScript -SessionId $conflictId -CodexHome $codexHome `
            -BackupRoot $backupRoot -BatchBackupDirectory $batchDirectory |
            Out-Null
    }
    catch {
        $conflictBlocked = $_.Exception.Message -like '*Runtime provider conflict*'
    }
    Assert-Equal $conflictBlocked $true 'A runtime provider conflict was not blocked.'
    $conflictFirst = [IO.File]::ReadAllLines($sessionPaths[$conflictId])[0]
    Assert-Equal (($conflictFirst | ConvertFrom-Json).payload.model_provider) 'custom' `
        'The blocked conflict JSONL changed unexpectedly.'

    $executeSql = @'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as connection:
    connection.execute(sys.argv[2])
'@
    $conflictHash = (Get-FileHash -LiteralPath $sessionPaths[$conflictId]).Hash
    Invoke-TestPython -Code $executeSql -Arguments @($databasePath, "create trigger refuse_update before update on threads begin select raise(abort, 'fixture database failure'); end")
    Assert-Refused {
        & $repairScript -SessionId $conflictId -CodexHome $codexHome -BackupRoot $backupRoot -BatchBackupDirectory $batchDirectory -RewriteRuntimeProvider
    } 'A database update failure must be reported.'
    Assert-Equal (Get-FileHash -LiteralPath $sessionPaths[$conflictId]).Hash $conflictHash 'Database failure did not roll back JSONL.'
    Assert-Equal (Get-Item -LiteralPath $sessionPaths[$conflictId]).LastWriteTimeUtc $fixedTime 'Rollback changed JSONL mtime.'
    Invoke-TestPython -Code $executeSql -Arguments @($databasePath, 'drop trigger refuse_update')
    # The failed attempt intentionally retains its backup; use a fresh batch for retry.
    $batchDirectory = Join-Path $backupRoot 'advanced-retry'
    $null = New-Item -ItemType Directory -Path $batchDirectory

    & $repairScript -SessionId $conflictId -CodexHome $codexHome `
        -BackupRoot $backupRoot -BatchBackupDirectory $batchDirectory `
        -RewriteRuntimeProvider | Out-Null
    $advancedLines = [IO.File]::ReadAllLines($sessionPaths[$conflictId])
    Assert-Equal (($advancedLines[0] | ConvertFrom-Json).payload.model_provider) 'openai' `
        'The advanced repair did not update the JSONL header.'
    Assert-Equal (
        ($advancedLines[1] | ConvertFrom-Json).payload.thread_settings.model_provider_id
    ) 'openai' 'The advanced repair did not update the latest runtime provider.'

    $advancedManifestPath = Join-Path $batchDirectory "sessions\$conflictId\manifest.json"
    $advancedManifest = Get-Content -LiteralPath $advancedManifestPath -Raw |
        ConvertFrom-Json
    Assert-Equal $advancedManifest.version 2 'The advanced manifest version is incorrect.'
    Assert-Equal @($advancedManifest.runtime_rewrites).Count 1 `
        'The advanced manifest did not record its runtime rewrite.'

    [IO.File]::AppendAllText(
        $sessionPaths[$conflictId],
        "{`"type`":`"event_msg`",`"payload`":{`"type`":`"fixture_after_repair`"}}`n",
        [Text.UTF8Encoding]::new($false)
    )
    & $restoreScript -ManifestPath $advancedManifestPath -BackupRoot $backupRoot `
        -Confirm:$false | Out-Null

    $restoredLines = [IO.File]::ReadAllLines($sessionPaths[$conflictId])
    Assert-Equal (($restoredLines[0] | ConvertFrom-Json).payload.model_provider) 'custom' `
        'Restore did not revert the JSONL header provider.'
    Assert-Equal (
        ($restoredLines[1] | ConvertFrom-Json).payload.thread_settings.model_provider_id
    ) 'custom' 'Restore did not revert the runtime provider.'
    Assert-Equal (($restoredLines[-1] | ConvertFrom-Json).payload.type) 'fixture_after_repair' `
        'Restore discarded content appended after the repair.'
    $restoredProviders = (Invoke-TestPython -Code $databaseCheck -Arguments @($databasePath)) |
        ConvertFrom-Json
    Assert-Equal $restoredProviders.PSObject.Properties[$conflictId].Value 'custom' `
        'Restore did not revert the database provider.'

    $backgroundBatch = Join-Path $backupRoot 'background-batch'
    $null = New-Item -ItemType Directory -Path $backgroundBatch
    $backgroundPlanPath = Join-Path $backgroundBatch 'batch-plan.json'
    $backgroundPlan = [ordered]@{
        version = 1
        created_at = (Get-Date).ToString('o')
        target_provider = 'openai'
        codex_home = $codexHome
        backup_root = $backupRoot
        batch_directory = $backgroundBatch
        items = @([ordered]@{
            session_id = $conflictId
            advanced = $true
        })
    }
    [IO.File]::WriteAllText(
        $backgroundPlanPath,
        ($backgroundPlan | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
    & $batchRepairScript -PlanPath $backgroundPlanPath
    $backgroundReport = Get-Content -LiteralPath (Join-Path $backgroundBatch 'batch-report.json') -Raw |
        ConvertFrom-Json
    Assert-Equal $backgroundReport.status 'completed' 'The background worker did not finish.'
    Assert-Equal $backgroundReport.success_count 1 'The background worker did not repair the task.'
    Assert-Equal $backgroundReport.failed_count 0 'The background worker reported an unexpected failure.'

    Invoke-TestPython -Code $executeSql -Arguments @($databasePath, 'alter table threads rename column model_provider to unsupported_provider')
    $unknownHash = (Get-FileHash -LiteralPath $sessionPaths[$conflictId]).Hash
    Assert-Refused {
        & $guiScript -ScanOnly -AllDates -SummaryOnly -CodexHome $codexHome
    } 'Scanning must refuse an unknown database schema.'
    Assert-Refused {
        & $repairScript -SessionId $conflictId -CodexHome $codexHome -BackupRoot $backupRoot -RewriteRuntimeProvider
    } 'Repair must refuse an unknown database schema.'
    Assert-Equal (Get-FileHash -LiteralPath $sessionPaths[$conflictId]).Hash $unknownHash 'Unknown-schema refusal changed JSONL.'

    Write-Output 'PASS: standard/advanced repair, restore, worker, backup, writers, stale snapshots, manifest failure, DB rollback, unknown schema.'
}
finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedTestRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $resolvedTestRoot -Leaf).StartsWith('codex-repair-smoke-')) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
