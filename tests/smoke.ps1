[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
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

$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
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
        "model_provider = `"openai`"`n",
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
    & $pythonCommand.Source @pythonArguments -c $databaseSetup $databasePath `
        $safeId1 $sessionPaths[$safeId1] `
        $safeId2 $sessionPaths[$safeId2] `
        $conflictId $sessionPaths[$conflictId]
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not create the smoke-test state database.'
    }

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
        $provider = ($first | ConvertFrom-Json -Depth 10).payload.model_provider
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
    $liveProviders = (& $pythonCommand.Source @pythonArguments -c $databaseCheck $databasePath) |
        ConvertFrom-Json -AsHashtable
    Assert-Equal $liveProviders[$safeId1] 'openai' 'The first database row was not repaired.'
    Assert-Equal $liveProviders[$safeId2] 'openai' 'The second database row was not repaired.'
    Assert-Equal $liveProviders[$conflictId] 'custom' 'The conflict database row changed unexpectedly.'

    $backupProviders = (& $pythonCommand.Source @pythonArguments -c $databaseCheck $databaseBackup) |
        ConvertFrom-Json -AsHashtable
    Assert-Equal $backupProviders[$safeId1] 'custom' 'The database snapshot is not a pre-batch backup.'
    Assert-Equal $backupProviders[$safeId2] 'custom' 'The shared database snapshot changed during the batch.'

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
    Assert-Equal (($conflictFirst | ConvertFrom-Json -Depth 10).payload.model_provider) 'custom' `
        'The blocked conflict JSONL changed unexpectedly.'

    & $repairScript -SessionId $conflictId -CodexHome $codexHome `
        -BackupRoot $backupRoot -BatchBackupDirectory $batchDirectory `
        -RewriteRuntimeProvider | Out-Null
    $advancedLines = [IO.File]::ReadAllLines($sessionPaths[$conflictId])
    Assert-Equal (($advancedLines[0] | ConvertFrom-Json -Depth 10).payload.model_provider) 'openai' `
        'The advanced repair did not update the JSONL header.'
    Assert-Equal (
        ($advancedLines[1] | ConvertFrom-Json -Depth 10).payload.thread_settings.model_provider_id
    ) 'openai' 'The advanced repair did not update the latest runtime provider.'

    $advancedManifestPath = Join-Path $batchDirectory "sessions\$conflictId\manifest.json"
    $advancedManifest = Get-Content -LiteralPath $advancedManifestPath -Raw |
        ConvertFrom-Json -Depth 20
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
    Assert-Equal (($restoredLines[0] | ConvertFrom-Json -Depth 10).payload.model_provider) 'custom' `
        'Restore did not revert the JSONL header provider.'
    Assert-Equal (
        ($restoredLines[1] | ConvertFrom-Json -Depth 10).payload.thread_settings.model_provider_id
    ) 'custom' 'Restore did not revert the runtime provider.'
    Assert-Equal (($restoredLines[-1] | ConvertFrom-Json -Depth 10).payload.type) 'fixture_after_repair' `
        'Restore discarded content appended after the repair.'
    $restoredProviders = (& $pythonCommand.Source @pythonArguments -c $databaseCheck $databasePath) |
        ConvertFrom-Json -AsHashtable
    Assert-Equal $restoredProviders[$conflictId] 'custom' `
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
        ConvertFrom-Json -Depth 20
    Assert-Equal $backgroundReport.status 'completed' 'The background worker did not finish.'
    Assert-Equal $backgroundReport.success_count 1 'The background worker did not repair the task.'
    Assert-Equal $backgroundReport.failed_count 0 'The background worker reported an unexpected failure.'

    Write-Output 'PASS: standard/advanced repair, targeted restore, background worker, backup, and conflict guard.'
}
finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedTestRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $resolvedTestRoot -Leaf).StartsWith('codex-repair-smoke-')) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
