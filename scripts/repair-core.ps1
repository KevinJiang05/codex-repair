[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SessionId,

    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$TargetProvider,

    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),

    [string]$BackupRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'backups'),

    [string]$BatchBackupDirectory,

    [switch]$RewriteRuntimeProvider
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'session-io.ps1')

$configPath = Join-Path $CodexHome 'config.toml'
$sessionsPath = Join-Path $CodexHome 'sessions'
$archivedSessionsPath = Join-Path $CodexHome 'archived_sessions'

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Codex config not found: $configPath"
}
if (-not (Test-Path -LiteralPath $sessionsPath -PathType Container)) {
    throw "Codex sessions directory not found: $sessionsPath"
}

$pythonCommand = Get-Command py -ErrorAction SilentlyContinue
$pythonArguments = @('-3')
if (-not $pythonCommand) {
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    $pythonArguments = @()
}
if (-not $pythonCommand) {
    throw 'Python 3 is required to inspect and update the Codex state database.'
}
$pythonBootstrap = 'import base64,sys;exec(base64.b64decode(sys.argv.pop(1)))'

$sqliteHelper = @'
import json
import os
import sqlite3
import sys

def normalize_windows_path(path):
    if path.startswith("\\\\?\\"):
        path = path[4:]
    return os.path.normcase(os.path.abspath(path))

mode, database, session_id = sys.argv[1:4]
target = sys.argv[4] if len(sys.argv) > 4 else None
expected_old = sys.argv[5] if len(sys.argv) > 5 else None
expected_rollout = sys.argv[6] if len(sys.argv) > 6 else None
backup = sys.argv[7] if len(sys.argv) > 7 else None
allow_existing_backup = len(sys.argv) > 8 and sys.argv[8].lower() == "true"

if mode == "inspect":
    uri = "file:" + database.replace("\\", "/") + "?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=10)
    try:
        columns = {row[1] for row in connection.execute("pragma table_info(threads)")}
        if not {"id", "rollout_path", "created_at", "model_provider", "title", "archived"} <= columns:
            raise SystemExit("Unsupported Codex state database schema; no repair was made.")
        row = connection.execute(
            "select model_provider, rollout_path from threads where id = ?",
            (session_id,),
        ).fetchone()
        print(json.dumps({
            "found": row is not None,
            "provider": row[0] if row else None,
            "rollout_path": row[1] if row else None,
        }))
    finally:
        connection.close()
    raise SystemExit(0)

if mode != "update":
    raise SystemExit("Unknown database operation: " + mode)

connection = sqlite3.connect(database, timeout=10)
connection.execute("pragma busy_timeout=10000")
row = connection.execute(
    "select model_provider, rollout_path from threads where id = ?",
    (session_id,),
).fetchone()
if row is None:
    connection.close()
    raise SystemExit("Target thread row is missing; no database change was made.")

old_provider, rollout_path = row
if old_provider != expected_old:
    connection.close()
    raise SystemExit(
        "Database provider changed since inspection; no database change was made."
    )
if normalize_windows_path(rollout_path) != normalize_windows_path(expected_rollout):
    connection.close()
    raise SystemExit("Rollout path mismatch; no database change was made.")

if not backup:
    connection.close()
    raise SystemExit("A database backup path is required; no change was made.")
if os.path.exists(backup):
    if not allow_existing_backup:
        connection.close()
        raise SystemExit("Database backup already exists; no change was made.")
    backup_uri = "file:" + backup.replace("\\", "/") + "?mode=ro"
    backup_connection = sqlite3.connect(backup_uri, uri=True, timeout=10)
    try:
        if backup_connection.execute("pragma quick_check").fetchone()[0] != "ok":
            connection.close()
            raise SystemExit("Existing batch database backup failed quick_check.")
    finally:
        backup_connection.close()
else:
    with sqlite3.connect(backup) as destination:
        connection.backup(destination)

try:
    connection.execute("begin immediate")
    cursor = connection.execute(
        "update threads set model_provider = ? "
        "where id = ? and model_provider = ? and rollout_path = ?",
        (target, session_id, old_provider, rollout_path),
    )
    if cursor.rowcount != 1:
        raise RuntimeError("Expected exactly one updated database row.")
    verified = connection.execute(
        "select model_provider, rollout_path from threads where id = ?",
        (session_id,),
    ).fetchone()
    if verified != (target, rollout_path):
        raise RuntimeError("Database post-write verification failed.")
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

    $encodedCode = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sqliteHelper))
    $output = & $pythonCommand.Source @pythonArguments -c $pythonBootstrap $encodedCode @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "SQLite helper failed with exit code $LASTEXITCODE."
    }
    return ($output | ConvertFrom-Json)
}

function Get-NormalizedWindowsPath {
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
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        $share
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

function Read-AllTextShared {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = Read-AllBytesShared -Path $Path
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function Read-FirstLineShared {
    param([Parameter(Mandatory = $true)][string]$Path)

    $content = Read-AllBytesShared -Path $Path
    $lineFeed = [Array]::IndexOf($content, [byte]10)
    if ($lineFeed -lt 0) {
        return [Text.Encoding]::UTF8.GetString($content)
    }
    $length = if ($lineFeed -gt 0 -and $content[$lineFeed - 1] -eq 13) {
        $lineFeed - 1
    }
    else {
        $lineFeed
    }
    return [Text.Encoding]::UTF8.GetString($content, 0, $length)
}

function Get-RuntimeProviderRecordsShared {
    param([Parameter(Mandatory = $true)][string]$Path)

    $records = [Collections.Generic.List[object]]::new()
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = [IO.FileStream]::new(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        $share
    )
    try {
        $reader = [IO.StreamReader]::new(
            $stream,
            [Text.Encoding]::UTF8,
            $true,
            4096,
            $true
        )
        try {
            $lineNumber = 0
            while (($line = $reader.ReadLine()) -ne $null) {
                $lineNumber++
                if (-not $line.Contains('thread_settings_applied')) {
                    continue
                }
                try {
                    $record = $line | ConvertFrom-Json
                }
                catch {
                    throw "Invalid JSON on session line $lineNumber; automatic repair refused."
                }
                if ($record.payload.type -eq 'thread_settings_applied') {
                    $runtimeProvider = [string]$record.payload.thread_settings.model_provider_id
                    if ($runtimeProvider) {
                        $records.Add([pscustomobject]@{
                            LineNumber = $lineNumber
                            Provider = $runtimeProvider
                            Line = $line
                        })
                    }
                }
            }
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
    return @($records)
}

function Set-JsonlLineBytes {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$LineNumber,
        [Parameter(Mandatory = $true)][string]$NewLine
    )

    if ($LineNumber -lt 1) {
        throw 'JSONL line number must be positive.'
    }
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
            $Bytes,
            $contentEnd,
            $result,
            $lineStart + $newLineBytes.Length,
            $lineEndingLength
        )
    }
    [Array]::Copy(
        $Bytes,
        $tailOffset,
        $result,
        $lineStart + $newLineBytes.Length + $lineEndingLength,
        $Bytes.Length - $tailOffset
    )
    return ,$result
}

$configText = Read-AllTextShared -Path $configPath
$rootConfig = ([regex]::Split($configText, '(?m)^\s*\['))[0]
$configuredProviderMatch = [regex]::Match(
    $rootConfig,
    '(?m)^\s*model_provider\s*=\s*"([A-Za-z0-9_-]+)"\s*(?:#.*)?$'
)

if (-not $TargetProvider) {
    if (-not $configuredProviderMatch.Success -and [regex]::IsMatch($rootConfig, '(?m)^\s*model_provider\s*=')) {
        throw 'Unsupported top-level model_provider syntax; repair refused.'
    }
    $TargetProvider = if ($configuredProviderMatch.Success) {
        $configuredProviderMatch.Groups[1].Value
    }
    else {
        'openai'
    }
}

$builtInProviders = @('openai', 'ollama', 'lmstudio', 'amazon-bedrock')
if ($TargetProvider -notin $builtInProviders) {
    $providerTablePattern = '(?m)^\s*\[model_providers\.' + [regex]::Escape($TargetProvider) + '\]\s*$'
    if (-not [regex]::IsMatch($configText, $providerTablePattern)) {
        throw "Target provider '$TargetProvider' is not defined in config.toml."
    }
}

$sessionSearchPaths = @($sessionsPath)
if (Test-Path -LiteralPath $archivedSessionsPath -PathType Container) {
    $sessionSearchPaths += $archivedSessionsPath
}
$sessionFiles = @(
    foreach ($searchPath in $sessionSearchPaths) {
        Get-ChildItem -LiteralPath $searchPath -Filter "*-$SessionId.jsonl" -File -Recurse
    }
)
if ($sessionFiles.Count -ne 1) {
    throw "Expected exactly one session file for '$SessionId'; found $($sessionFiles.Count)."
}

$sessionFile = $sessionFiles[0].FullName
try {
    $bytes = Read-AllBytesShared -Path $sessionFile
}
catch [IO.IOException] {
    throw "Session file is currently locked by another process. Close the task and retry: $sessionFile"
}
$lineFeedIndex = [Array]::IndexOf($bytes, [byte]10)
if ($lineFeedIndex -lt 0) {
    throw 'Session file has no complete first line.'
}

$firstLineLength = if ($lineFeedIndex -gt 0 -and $bytes[$lineFeedIndex - 1] -eq 13) {
    $lineFeedIndex - 1
}
else {
    $lineFeedIndex
}
$firstLine = [Text.Encoding]::UTF8.GetString($bytes, 0, $firstLineLength)
$metadata = $firstLine | ConvertFrom-Json

if ($metadata.type -ne 'session_meta') {
    throw "First record is '$($metadata.type)', not session_meta."
}
if ($metadata.payload.id -ne $SessionId) {
    throw "Session id mismatch: file contains '$($metadata.payload.id)'."
}

$oldProvider = [string]$metadata.payload.model_provider
if (-not $oldProvider) {
    throw 'session_meta.payload.model_provider is missing or empty.'
}

try {
    $runtimeRecords = @(Get-RuntimeProviderRecordsShared -Path $sessionFile)
}
catch [IO.IOException] {
    throw "Session file is currently locked by another process. Close the task and retry: $sessionFile"
}
$runtimeProviders = @($runtimeRecords | ForEach-Object { $_.Provider })
$runtimeProviderSet = @($runtimeProviders | Sort-Object -Unique)
$runtimeLatestRecord = if ($runtimeRecords.Count -gt 0) {
    $runtimeRecords[-1]
}
else {
    $null
}
$runtimeLatestProvider = if ($runtimeLatestRecord) { [string]$runtimeLatestRecord.Provider } else { $null }
$runtimeNeedsChange = $runtimeLatestProvider -and $runtimeLatestProvider -ne $TargetProvider
if ($runtimeNeedsChange -and -not $RewriteRuntimeProvider) {
    throw "Runtime provider conflict found ($runtimeLatestProvider); automatic repair refused."
}

$stateDatabaseCandidates = @(
    Get-ChildItem -LiteralPath $CodexHome -File -Filter 'state_*.sqlite' |
        Where-Object { $_.Name -match '^state_[0-9]+\.sqlite$' }
)
$databaseMatches = @()
foreach ($candidate in $stateDatabaseCandidates) {
    $inspection = Invoke-SqliteHelper -Arguments @(
        'inspect', $candidate.FullName, $SessionId
    )
    if ($inspection.found) {
        $databaseMatches += [pscustomobject]@{
            Path = $candidate.FullName
            Provider = [string]$inspection.provider
            RolloutPath = [string]$inspection.rollout_path
        }
    }
}
if ($databaseMatches.Count -ne 1) {
    throw "Expected the session in exactly one state database; found $($databaseMatches.Count)."
}

$databaseMatch = $databaseMatches[0]
$stateDatabasePath = $databaseMatch.Path
$databaseProvider = $databaseMatch.Provider
if (-not $databaseProvider) {
    throw 'The state database model_provider is missing or empty.'
}
if ((Get-NormalizedWindowsPath $databaseMatch.RolloutPath) -ne
    (Get-NormalizedWindowsPath $sessionFile)) {
    throw 'The state database rollout path does not match the session file.'
}

$sessionNeedsChange = $oldProvider -ne $TargetProvider
$sessionContentNeedsChange = $sessionNeedsChange -or $runtimeNeedsChange
$databaseNeedsChange = $databaseProvider -ne $TargetProvider
if (-not $sessionContentNeedsChange -and -not $databaseNeedsChange) {
    Write-Output "No change needed: session '$SessionId' already uses '$TargetProvider' in all detected stores."
    return
}

$newBytes = $bytes
if ($sessionNeedsChange) {
    $oldMarker = '"model_provider":"' + $oldProvider + '"'
    $newMarker = '"model_provider":"' + $TargetProvider + '"'
    $markerCount = ([regex]::Matches($firstLine, [regex]::Escape($oldMarker))).Count
    if ($markerCount -ne 1) {
        throw "Expected one model_provider marker in session_meta; found $markerCount."
    }

    $newFirstLine = $firstLine.Replace($oldMarker, $newMarker)
    $newBytes = Set-JsonlLineBytes -Bytes $newBytes -LineNumber 1 -NewLine $newFirstLine
}

$runtimeRewrites = @()
if ($runtimeNeedsChange) {
    $runtimePattern = '("model_provider_id"\s*:\s*)"' +
        [regex]::Escape($runtimeLatestProvider) + '"'
    $runtimeRegex = [regex]::new($runtimePattern)
    $runtimeMarkerCount = $runtimeRegex.Matches([string]$runtimeLatestRecord.Line).Count
    if ($runtimeMarkerCount -ne 1) {
        throw "Expected one runtime provider marker on line $($runtimeLatestRecord.LineNumber); found $runtimeMarkerCount."
    }
    $newRuntimeLine = $runtimeRegex.Replace(
        [string]$runtimeLatestRecord.Line,
        [Text.RegularExpressions.MatchEvaluator]{
            param($match)
            return $match.Groups[1].Value + '"' + $TargetProvider + '"'
        },
        1
    )
    $newBytes = Set-JsonlLineBytes -Bytes $newBytes `
        -LineNumber $runtimeLatestRecord.LineNumber -NewLine $newRuntimeLine
    $runtimeRewrites = @([ordered]@{
        line_number = [int]$runtimeLatestRecord.LineNumber
        before = $runtimeLatestProvider
        after = $TargetProvider
    })
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$normalizedBackupRoot = [IO.Path]::GetFullPath($BackupRoot)
if ($BatchBackupDirectory) {
    $normalizedBatchDirectory = [IO.Path]::GetFullPath($BatchBackupDirectory)
    if (-not $normalizedBatchDirectory.StartsWith(
        $normalizedBackupRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Batch backup directory must be inside BackupRoot.'
    }
    $backupDirectory = Join-Path $normalizedBatchDirectory "sessions\$SessionId"
}
else {
    $normalizedBatchDirectory = $null
    $backupDirectory = Join-Path $normalizedBackupRoot "$timestamp-$SessionId"
}
$sessionBackupPath = if ($sessionContentNeedsChange) {
    Join-Path $backupDirectory "$(Split-Path $sessionFile -Leaf).bak"
}
else {
    $null
}
$databaseBackupPath = if ($databaseNeedsChange) {
    if ($normalizedBatchDirectory) {
        Join-Path $normalizedBatchDirectory "$(Split-Path $stateDatabasePath -Leaf).bak"
    }
    else {
        Join-Path $backupDirectory "$(Split-Path $stateDatabasePath -Leaf).bak"
    }
}
else {
    $null
}

if ($PSCmdlet.ShouldProcess(
    "$sessionFile and $stateDatabasePath",
    "synchronize model_provider to '$TargetProvider'"
)) {
    $sessionFileReplaced = $false
    $sessionGuard = $null
    $replacementGuard = $null
    try {
        $sessionGuard = Open-SessionWriteGuard -Path $sessionFile -ExpectedBytes $bytes
        $null = New-Item -ItemType Directory -Path $backupDirectory -Force
        if ($sessionContentNeedsChange) {
            Copy-Item -LiteralPath $sessionFile -Destination $sessionBackupPath
        }
        $manifest = [ordered]@{
            version = 2
            created_at = (Get-Date).ToString('o')
            session_id = $SessionId
            target_provider = $TargetProvider
            session_file = $sessionFile
            session_provider_before = $oldProvider
            session_backup = $sessionBackupPath
            state_database = $stateDatabasePath
            database_provider_before = $databaseProvider
            database_backup = $databaseBackupPath
            runtime_providers = $runtimeProviderSet
            runtime_latest_provider = $runtimeLatestProvider
            runtime_rewrites = $runtimeRewrites
            batch_backup_directory = $normalizedBatchDirectory
        }
        [IO.File]::WriteAllText(
            (Join-Path $backupDirectory 'manifest.json'),
            ($manifest | ConvertTo-Json -Depth 5),
            [Text.UTF8Encoding]::new($false)
        )
        if ($sessionContentNeedsChange) {
            $originalLastWriteTimeUtc = (Get-Item -LiteralPath $sessionFile).LastWriteTimeUtc
            $temporarySessionPath = "$sessionFile.codex-repair-$timestamp.tmp"
            [IO.File]::WriteAllBytes($temporarySessionPath, $newBytes)
            $verifyLine = Read-FirstLineShared -Path $temporarySessionPath
            $verifyMetadata = $verifyLine | ConvertFrom-Json
            if ($verifyMetadata.payload.id -ne $SessionId -or
                $verifyMetadata.payload.model_provider -ne $TargetProvider) {
                throw 'Session file post-write verification failed.'
            }
            if ($runtimeNeedsChange) {
                $verifyRuntimeRecords = @(Get-RuntimeProviderRecordsShared -Path $temporarySessionPath)
                $verifyRuntimeProvider = if ($verifyRuntimeRecords.Count) {
                    [string]$verifyRuntimeRecords[-1].Provider
                }
                else { $null }
                if ($verifyRuntimeProvider -ne $TargetProvider) {
                    throw 'Runtime provider post-write verification failed.'
                }
            }
            Complete-SessionReplacement -Path $sessionFile -TemporaryPath $temporarySessionPath -LastWriteTimeUtc $originalLastWriteTimeUtc
            $sessionFileReplaced = $true
            $replacementGuard = Open-SessionWriteGuard -Path $sessionFile -ExpectedBytes $newBytes
        }

        $databaseUpdate = $null
        if ($databaseNeedsChange) {
            $databaseUpdate = Invoke-SqliteHelper -Arguments @(
                'update',
                $stateDatabasePath,
                $SessionId,
                $TargetProvider,
                $databaseProvider,
                $sessionFile,
                $databaseBackupPath,
                $(if ($normalizedBatchDirectory) { 'true' } else { 'false' })
            )
        }
    }
    catch {
        if ($temporarySessionPath -and (Test-Path -LiteralPath $temporarySessionPath)) {
            Remove-Item -LiteralPath $temporarySessionPath -Force -ErrorAction SilentlyContinue
        }
        if ($sessionFileReplaced -and $sessionBackupPath -and (Test-Path -LiteralPath $sessionBackupPath)) {
            if (-not $replacementGuard) {
                throw 'JSONL was replaced but another writer intervened. Content was retained; close the task and restore from the saved manifest.'
            }
            [IO.File]::WriteAllBytes($temporarySessionPath, $bytes)
            Complete-SessionReplacement -Path $sessionFile -TemporaryPath $temporarySessionPath -LastWriteTimeUtc $originalLastWriteTimeUtc
        }
        throw
    }
    finally {
        if ($replacementGuard) { $replacementGuard.Dispose() }
        if ($sessionGuard) { $sessionGuard.Dispose() }
        if ($temporarySessionPath -and [IO.File]::Exists($temporarySessionPath)) {
            [IO.File]::Delete($temporarySessionPath)
        }
    }

    Write-Output "Updated session: $SessionId"
    if ($sessionContentNeedsChange) {
        if ($sessionNeedsChange) {
            Write-Output "Session file provider: $oldProvider -> $TargetProvider"
        }
        if ($runtimeNeedsChange) {
            Write-Output "Runtime provider on line $($runtimeLatestRecord.LineNumber): $runtimeLatestProvider -> $TargetProvider"
        }
        Write-Output "Session backup: $sessionBackupPath"
    }
    if ($databaseNeedsChange) {
        Write-Output "State database provider: $databaseProvider -> $TargetProvider"
        Write-Output "Database backup: $($databaseUpdate.backup)"
    }
    Write-Output "Backup directory: $backupDirectory"
    Write-Output 'Restart or reopen the Codex task to reload it.'
}
