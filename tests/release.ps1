[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$projectRoot = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $projectRoot 'VERSION') -Raw).Trim()
foreach ($flavor in @('script', 'win-x64')) {
    $name = "CodexRepair-v$version-$flavor"
    $path = Join-Path $projectRoot "dist\$name.zip"
    $expectedZipHash = ((Get-Content -LiteralPath "$path.sha256" -Raw).Trim() -split '\s+')[0]
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedZipHash) {
        throw "Archive hash does not match: $name"
    }
    $zip = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $entries = @{}
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName.EndsWith('/')) { continue }
            $relative = $entry.FullName.Replace('\', '/')
            if (-not $relative.StartsWith("$name/")) { throw "Unexpected archive root: $relative" }
            $relative = $relative.Substring($name.Length + 1)
            if ($relative -match '(^|/)(backups|sessions|archived_sessions|\.env|\.tmp)(/|$)|\.(jsonl|sqlite|bak|pdb)$') {
                throw "Private/runtime data in release: $relative"
            }
            if ($flavor -eq 'script' -and $relative -match '\.(exe|dll)$') { throw "Binary in script release: $relative" }
            $entries[$relative] = $entry
        }
        foreach ($required in @('Codex Repair.cmd', 'VERSION', 'LICENSE', 'SHA256SUMS.txt')) {
            if (-not $entries.ContainsKey($required)) { throw "Missing release file: $required" }
        }
        if ($flavor -eq 'script') {
            if (-not $entries.ContainsKey('scripts/session-io.ps1')) { throw 'Script package is missing shared session I/O.' }
        }
        else {
            foreach ($required in @('app/CodexRepair.exe', 'app/coreclr.dll', 'app/e_sqlite3.dll', 'licenses/dotnet-LICENSE.txt')) {
                if (-not $entries.ContainsKey($required)) { throw "Incomplete self-contained release: $required" }
            }
        }
        $reader = [IO.StreamReader]::new($entries['SHA256SUMS.txt'].Open())
        try { $hashLines = $reader.ReadToEnd() -split '\r?\n' | Where-Object { $_ } }
        finally { $reader.Dispose() }
        $seen = @{}
        foreach ($line in $hashLines) {
            if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw 'Invalid checksum record.' }
            $expectedHash = $Matches[1]
            $relative = $Matches[2]
            if (-not $entries.ContainsKey($relative) -or $seen.ContainsKey($relative)) {
                throw "Invalid or duplicate checksum path: $relative"
            }
            $stream = $entries[$relative].Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $actualHash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
            finally { $sha.Dispose(); $stream.Dispose() }
            if ($actualHash -ne $expectedHash) { throw "Content checksum failed: $relative" }
            $seen[$relative] = $true
        }
        if ($seen.Count -ne $entries.Count - 1) { throw "Unhashed release files: $name" }
        Write-Output "PASS: $name; $($seen.Count) content hashes; no session/backup content."
    }
    finally { $zip.Dispose() }
}
