[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [string]$BackupRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'backups')
)

$ErrorActionPreference = 'Stop'

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($Path.StartsWith('\\?\')) {
        $Path = $Path.Substring(4)
    }
    return [IO.Path]::GetFullPath($Path)
}

function Read-AllBytesShared {
    param([Parameter(Mandatory = $true)][string]$Path)

    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = [IO.FileStream]::new(
        $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share
    )
    try {
        $memory = [IO.MemoryStream]::new()
        try {
            $stream.CopyTo($memory)
            return ,($memory.ToArray())
        }
        finally {
            $memory.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-JsonlLine {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$LineNumber
    )

    if ($LineNumber -lt 1) {
        throw 'JSONL line number must be positive.'
    }
    $lineStart = 0
    for ($currentLine = 1; $currentLine -lt $LineNumber; $currentLine++) {
        $feed = [Array]::IndexOf($Bytes, [byte]10, $lineStart)
        if ($feed -lt 0) {
            throw "JSONL line $LineNumber does not exist."
        }
        $lineStart = $feed + 1
    }
    $lineFeed = [Array]::IndexOf($Bytes, [byte]10, $lineStart)
    $contentEnd = if ($lineFeed -lt 0) {
        $Bytes.Length
    }
    elseif ($lineFeed -gt $lineStart -and $Bytes[$lineFeed - 1] -eq 13) {
        $lineFeed - 1
    }
    else {
        $lineFeed
    }
    return [Text.Encoding]::UTF8.GetString($Bytes, $lineStart, $contentEnd - $lineStart)
}

function Set-JsonlLineBytes {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$LineNumber,
        [Parameter(Mandatory = $true)][string]$NewLine
    )

    $lineStart = 0
    for ($currentLine = 1; $currentLine -lt $LineNumber; $currentLine++) {
        $previousFeed = [Array]::IndexOf($Bytes, [byte]10, $lineStart)
        if ($previousFeed -lt 0) {
            throw "JSONL line $LineNumber does not exist."
        }
        $lineStart = $previousFeed + 1
    }
    $lineFeed = [Array]::IndexOf($Bytes, [byte]10, $lineStart)
    if ($lineFeed -lt 0) {
        $contentEnd = $Bytes.Length
        $tailOffset = $Bytes.Length
        $lineEndingLength = 0
    }
    else {
        $contentEnd = if ($lineFeed -gt $lineStart -and $Bytes[$lineFeed - 1] -eq 13) {
            $lineFeed - 1
        }
        else {
            $lineFeed
        }
        $tailOffset = $lineFeed + 1
        $lineEndingLength = $tailOffset - $contentEnd
    }
    $newLineBytes = [Text.Encoding]::UTF8.GetBytes($NewLine)
    $result = New-Object byte[] (
        $lineStart + $newLineBytes.Length + $lineEndingLength + $Bytes.Length - $tailOffset
    )
    [Array]::Copy($Bytes, 0, $result, 0, $lineStart)
    [Array]::Copy($newLineBytes, 0, $result, $lineStart, $newLineBytes.Length)
    if ($lineEndingLength -gt 0) {
        [Array]::Copy(
            $Bytes, $contentEnd, $result,
            $lineStart + $newLineBytes.Length, $lineEndingLength
        )
    }
    [Array]::Copy(
        $Bytes, $tailOffset, $result,
        $lineStart + $newLineBytes.Length + $lineEndingLength,
        $Bytes.Length - $tailOffset
    )
    return ,$result
}

function Get-RuntimeRecords {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $records = [Collections.Generic.List[object]]::new()
    $lineNumber = 0
    $text = [Text.Encoding]::UTF8.GetString($Bytes)
    $reader = [IO.StringReader]::new($text)
    try {
        while (($line = $reader.ReadLine()) -ne $null) {
            $lineNumber++
            if (-not $line.Contains('thread_settings_applied')) {
                continue
            }
            $record = $line | ConvertFrom-Json -Depth 100
            if ($record.payload.type -eq 'thread_settings_applied') {
                $provider = [string]$record.payload.thread_settings.model_provider_id
                if ($provider) {
                    $records.Add([pscustomobject]@{
                        LineNumber = $lineNumber
                        Provider = $provider
                    })
                }
            }
        }
    }
    finally {
        $reader.Dispose()
    }
    return @($records)
}

$normalizedBackupRoot = Get-NormalizedPath $BackupRoot
$normalizedManifest = Get-NormalizedPath $ManifestPath
if (-not $normalizedManifest.StartsWith(
    $normalizedBackupRoot + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'The selected manifest must be inside this portable copy backup directory.'
}
if ((Split-Path $normalizedManifest -Leaf) -ne 'manifest.json') {
    throw 'Select a task manifest.json, not batch-report.json.'
}
if (-not (Test-Path -LiteralPath $normalizedManifest -PathType Leaf)) {
    throw "Backup manifest not found: $normalizedManifest"
}

$manifest = Get-Content -LiteralPath $normalizedManifest -Raw | ConvertFrom-Json -Depth 20
$sessionId = [string]$manifest.session_id
$targetProvider = [string]$manifest.target_provider
$sessionProviderBefore = [string]$manifest.session_provider_before
$databaseProviderBefore = [string]$manifest.database_provider_before
$stateDatabasePath = Get-NormalizedPath ([string]$manifest.state_database)
$providerPattern = '^[A-Za-z0-9_-]+$'
if ($sessionId -notmatch '^[0-9a-fA-F-]{36}$' -or
    $targetProvider -notmatch $providerPattern) {
    throw 'The backup manifest is missing a valid session id or target provider.'
}
foreach ($providerValue in @($sessionProviderBefore, $databaseProviderBefore)) {
    if ($providerValue -and $providerValue -notmatch $providerPattern) {
        throw 'The backup manifest contains an invalid provider value.'
    }
}
if ((Split-Path $stateDatabasePath -Leaf) -notmatch '^state_[0-9]+\.sqlite$') {
    throw 'The backup manifest does not reference a recognized Codex state database.'
}
if (-not (Test-Path -LiteralPath $stateDatabasePath -PathType Leaf)) {
    throw "Current Codex state database not found: $stateDatabasePath"
}

$pythonCommand = Get-Command py -ErrorAction SilentlyContinue
$pythonArguments = @('-3')
if (-not $pythonCommand) {
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    $pythonArguments = @()
}
if (-not $pythonCommand) {
    throw 'Python 3 is required to restore the Codex state database.'
}

$sqliteHelper = @'
import json
import os
import sqlite3
import sys

mode, database, session_id = sys.argv[1:4]
connection = sqlite3.connect(database, timeout=10)
connection.execute("pragma busy_timeout=10000")
row = connection.execute(
    "select model_provider, rollout_path from threads where id = ?",
    (session_id,),
).fetchone()
if mode == "inspect":
    connection.close()
    print(json.dumps({
        "found": row is not None,
        "provider": row[0] if row else None,
        "rollout_path": row[1] if row else None,
    }))
    raise SystemExit(0)

expected_current, restore_provider, expected_rollout, backup = sys.argv[4:8]
if row is None:
    connection.close()
    raise SystemExit("Target thread row is missing; no restore was made.")
if row[0] != expected_current:
    connection.close()
    raise SystemExit("Database provider changed after the repair; restore refused.")
if os.path.normcase(os.path.abspath(row[1])) != os.path.normcase(os.path.abspath(expected_rollout)):
    connection.close()
    raise SystemExit("Database rollout path changed; restore refused.")
if os.path.exists(backup):
    connection.close()
    raise SystemExit("Pre-restore database backup already exists.")
with sqlite3.connect(backup) as destination:
    connection.backup(destination)
try:
    connection.execute("begin immediate")
    cursor = connection.execute(
        "update threads set model_provider = ? where id = ? and model_provider = ?",
        (restore_provider, session_id, expected_current),
    )
    if cursor.rowcount != 1:
        raise RuntimeError("Expected exactly one restored database row.")
    connection.commit()
except Exception:
    connection.rollback()
    raise
finally:
    connection.close()
print(json.dumps({"backup": backup}))
'@

function Invoke-SqliteHelper {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & $pythonCommand.Source @pythonArguments -c $sqliteHelper @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "SQLite restore helper failed with exit code $LASTEXITCODE."
    }
    return ($output | ConvertFrom-Json)
}

$inspection = Invoke-SqliteHelper -Arguments @('inspect', $stateDatabasePath, $sessionId)
if (-not $inspection.found) {
    throw "Session '$sessionId' is no longer present in the recorded state database."
}
$sessionFile = Get-NormalizedPath ([string]$inspection.rollout_path)
if (-not (Test-Path -LiteralPath $sessionFile -PathType Leaf)) {
    throw "Current session file not found: $sessionFile"
}
if ((Split-Path $sessionFile -Leaf) -notlike "*-$sessionId.jsonl") {
    throw 'The current session file name does not match the manifest session id.'
}

try {
    $bytes = Read-AllBytesShared -Path $sessionFile
}
catch [IO.IOException] {
    throw "Session file is currently locked. Close the task and retry: $sessionFile"
}
$newBytes = $bytes
$firstLine = Get-JsonlLine -Bytes $newBytes -LineNumber 1
$metadata = $firstLine | ConvertFrom-Json -Depth 100
if ($metadata.type -ne 'session_meta' -or $metadata.payload.id -ne $sessionId) {
    throw 'Current session metadata does not match the backup manifest.'
}

$sessionNeedsRestore = $sessionProviderBefore -and $sessionProviderBefore -ne $targetProvider
if ($sessionNeedsRestore) {
    if (-not $manifest.session_backup -or
        -not (Test-Path -LiteralPath ([string]$manifest.session_backup) -PathType Leaf)) {
        throw 'The original JSONL backup referenced by the manifest is missing.'
    }
    if ([string]$metadata.payload.model_provider -ne $targetProvider) {
        throw 'Session header provider changed after the repair; restore refused.'
    }
    $headerPattern = '("model_provider"\s*:\s*)"' + [regex]::Escape($targetProvider) + '"'
    $headerRegex = [regex]::new($headerPattern)
    if ($headerRegex.Matches($firstLine).Count -ne 1) {
        throw 'Expected exactly one restorable session header provider marker.'
    }
    $restoredFirstLine = $headerRegex.Replace(
        $firstLine,
        [Text.RegularExpressions.MatchEvaluator]{
            param($match)
            return $match.Groups[1].Value + '"' + $sessionProviderBefore + '"'
        },
        1
    )
    $newBytes = Set-JsonlLineBytes -Bytes $newBytes -LineNumber 1 -NewLine $restoredFirstLine
}

$runtimeRewrites = @($manifest.runtime_rewrites)
if ($runtimeRewrites.Count -gt 0) {
    if (-not $manifest.session_backup -or
        -not (Test-Path -LiteralPath ([string]$manifest.session_backup) -PathType Leaf)) {
        throw 'The original JSONL backup referenced by the runtime rewrite is missing.'
    }
    $runtimeRecords = @(Get-RuntimeRecords -Bytes $bytes)
    $latestRuntimeLine = if ($runtimeRecords.Count) { [int]$runtimeRecords[-1].LineNumber } else { 0 }
    $recordedLatestLine = [int]$runtimeRewrites[-1].line_number
    if ($latestRuntimeLine -ne $recordedLatestLine) {
        throw 'New runtime settings were written after this repair; runtime restore refused.'
    }
    foreach ($rewrite in $runtimeRewrites) {
        $lineNumber = [int]$rewrite.line_number
        $before = [string]$rewrite.before
        $after = [string]$rewrite.after
        if ($before -notmatch $providerPattern -or $after -notmatch $providerPattern) {
            throw 'The runtime rewrite manifest contains an invalid provider value.'
        }
        if ($after -ne $targetProvider) {
            throw 'The runtime rewrite target does not match the manifest target provider.'
        }
        $line = Get-JsonlLine -Bytes $newBytes -LineNumber $lineNumber
        $record = $line | ConvertFrom-Json -Depth 100
        if ($record.payload.type -ne 'thread_settings_applied' -or
            [string]$record.payload.thread_settings.model_provider_id -ne $after) {
            throw "Runtime provider on line $lineNumber changed after the repair; restore refused."
        }
        $runtimePattern = '("model_provider_id"\s*:\s*)"' + [regex]::Escape($after) + '"'
        $runtimeRegex = [regex]::new($runtimePattern)
        if ($runtimeRegex.Matches($line).Count -ne 1) {
            throw "Expected exactly one restorable runtime provider marker on line $lineNumber."
        }
        $restoredLine = $runtimeRegex.Replace(
            $line,
            [Text.RegularExpressions.MatchEvaluator]{
                param($match)
                return $match.Groups[1].Value + '"' + $before + '"'
            },
            1
        )
        $newBytes = Set-JsonlLineBytes -Bytes $newBytes `
            -LineNumber $lineNumber -NewLine $restoredLine
    }
    $sessionNeedsRestore = $true
}

$databaseNeedsRestore = $databaseProviderBefore -and $databaseProviderBefore -ne $targetProvider
if ($databaseNeedsRestore -and
    (-not $manifest.database_backup -or
        -not (Test-Path -LiteralPath ([string]$manifest.database_backup) -PathType Leaf))) {
    throw 'The original state database backup referenced by the manifest is missing.'
}
if ($databaseNeedsRestore -and [string]$inspection.provider -ne $targetProvider) {
    throw 'Database provider changed after the repair; restore refused.'
}
if (-not $sessionNeedsRestore -and -not $databaseNeedsRestore) {
    Write-Output "No restore needed for '$sessionId'."
    return
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$recoveryDirectory = Join-Path $normalizedBackupRoot "$timestamp-pre-restore-$sessionId"
$sessionRecoveryPath = if ($sessionNeedsRestore) {
    Join-Path $recoveryDirectory "$(Split-Path $sessionFile -Leaf).bak"
}
else { $null }
$databaseRecoveryPath = if ($databaseNeedsRestore) {
    Join-Path $recoveryDirectory "$(Split-Path $stateDatabasePath -Leaf).bak"
}
else { $null }

if ($PSCmdlet.ShouldProcess(
    "$sessionFile and $stateDatabasePath",
    "restore provider state recorded by $normalizedManifest"
)) {
    $null = New-Item -ItemType Directory -Path $recoveryDirectory
    $sessionReplaced = $false
    try {
        if ($sessionNeedsRestore) {
            $originalLastWriteTimeUtc = (Get-Item -LiteralPath $sessionFile).LastWriteTimeUtc
            Copy-Item -LiteralPath $sessionFile -Destination $sessionRecoveryPath
            $temporaryPath = "$sessionFile.codex-restore-$timestamp.tmp"
            [IO.File]::WriteAllBytes($temporaryPath, $newBytes)
            $verifyMetadata = (Get-JsonlLine -Bytes (Read-AllBytesShared $temporaryPath) -LineNumber 1) |
                ConvertFrom-Json -Depth 100
            if ($verifyMetadata.payload.id -ne $sessionId) {
                throw 'Restored session verification failed.'
            }
            [IO.File]::Move($temporaryPath, $sessionFile, $true)
            $sessionReplaced = $true
            (Get-Item -LiteralPath $sessionFile).LastWriteTimeUtc = $originalLastWriteTimeUtc
        }
        if ($databaseNeedsRestore) {
            $null = Invoke-SqliteHelper -Arguments @(
                'update', $stateDatabasePath, $sessionId, $targetProvider,
                $databaseProviderBefore, $sessionFile, $databaseRecoveryPath
            )
        }
    }
    catch {
        if ($temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        if ($sessionReplaced -and (Test-Path -LiteralPath $sessionRecoveryPath)) {
            Copy-Item -LiteralPath $sessionRecoveryPath -Destination $sessionFile -Force
            (Get-Item -LiteralPath $sessionFile).LastWriteTimeUtc = $originalLastWriteTimeUtc
        }
        throw
    }

    $restoreReport = [ordered]@{
        version = 1
        operation = 'pre_restore_backup'
        created_at = (Get-Date).ToString('o')
        source_manifest = $normalizedManifest
        session_id = $sessionId
        session_file = $sessionFile
        session_backup = $sessionRecoveryPath
        state_database = $stateDatabasePath
        database_backup = $databaseRecoveryPath
    }
    try {
        [IO.File]::WriteAllText(
            (Join-Path $recoveryDirectory 'restore-report.json'),
            ($restoreReport | ConvertTo-Json -Depth 5),
            [Text.UTF8Encoding]::new($false)
        )
    }
    catch {
        Write-Warning "Restore succeeded, but the restore report could not be written: $($_.Exception.Message)"
    }
    Write-Output "Restored session: $sessionId"
    Write-Output "Pre-restore backup: $recoveryDirectory"
    Write-Output 'Reopen the Codex task to reload it.'
}
