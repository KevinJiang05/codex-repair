[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $projectRoot 'VERSION') -Raw).Trim()
$distRoot = Join-Path $projectRoot 'dist'
$packageName = "CodexRepair-v$version-script"
$packageDirectory = Join-Path $distRoot $packageName
$zipPath = Join-Path $distRoot "$packageName.zip"

$requiredSources = @(
    'script-package\Codex Repair.cmd'
    'SCRIPT_README.txt'
    'VERSION'
    'LICENSE'
    'scripts\repair-gui.ps1'
    'scripts\repair-batch.ps1'
    'scripts\repair-core.ps1'
    'scripts\restore-core.ps1'
    'scripts\session-io.ps1'
)
foreach ($relativePath in $requiredSources) {
    if (-not (Test-Path -LiteralPath (Join-Path $projectRoot $relativePath) -PathType Leaf)) {
        throw "Required source file is missing: $relativePath"
    }
}

if ((Test-Path -LiteralPath $packageDirectory) -or (Test-Path -LiteralPath $zipPath)) {
    if (-not $Force) {
        throw "Release $packageName already exists. Re-run with -Force to replace that exact version."
    }
    $normalizedDist = [IO.Path]::GetFullPath($distRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    foreach ($target in @($packageDirectory, $zipPath)) {
        $normalizedTarget = [IO.Path]::GetFullPath($target)
        if (-not $normalizedTarget.StartsWith($normalizedDist, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to replace a path outside dist: $normalizedTarget"
        }
        if (Test-Path -LiteralPath $normalizedTarget) {
            Remove-Item -LiteralPath $normalizedTarget -Recurse -Force
        }
    }
}

$null = New-Item -ItemType Directory -Path (Join-Path $packageDirectory 'scripts') -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'script-package\Codex Repair.cmd') -Destination $packageDirectory
Copy-Item -LiteralPath (Join-Path $projectRoot 'SCRIPT_README.txt') -Destination $packageDirectory
Copy-Item -LiteralPath (Join-Path $projectRoot 'VERSION') -Destination $packageDirectory
Copy-Item -LiteralPath (Join-Path $projectRoot 'LICENSE') -Destination $packageDirectory
foreach ($scriptName in @('repair-gui.ps1', 'repair-batch.ps1', 'repair-core.ps1', 'restore-core.ps1', 'session-io.ps1')) {
    Copy-Item -LiteralPath (Join-Path $projectRoot "scripts\$scriptName") `
        -Destination (Join-Path $packageDirectory 'scripts')
}

$forbidden = @(Get-ChildItem -LiteralPath $packageDirectory -Recurse -Force |
    Where-Object { $_.Name -in @('backups', 'sessions') -or $_.Extension -in @('.jsonl', '.sqlite', '.bak', '.exe', '.dll') })
if ($forbidden.Count -gt 0) {
    throw 'Script release validation found forbidden binary, session, or backup content.'
}

$parseErrors = @()
foreach ($script in Get-ChildItem -LiteralPath (Join-Path $packageDirectory 'scripts') -Filter '*.ps1' -File) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors)
    $parseErrors += $errors
}
if ($parseErrors.Count -gt 0) {
    throw "Packaged PowerShell syntax validation failed: $($parseErrors[0].Message)"
}

$hashLines = foreach ($file in Get-ChildItem -LiteralPath $packageDirectory -File -Recurse | Sort-Object FullName) {
    $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
    $relative = $file.FullName.Substring($packageDirectory.Length + 1).Replace('\', '/')
    "$($hash.Hash.ToLowerInvariant())  $relative"
}
[IO.File]::WriteAllText(
    (Join-Path $packageDirectory 'SHA256SUMS.txt'),
    (($hashLines -join "`r`n") + "`r`n"),
    [Text.UTF8Encoding]::new($false)
)

Compress-Archive -LiteralPath $packageDirectory -DestinationPath $zipPath -CompressionLevel Optimal
$zipHash = Get-FileHash -LiteralPath $zipPath -Algorithm SHA256
[IO.File]::WriteAllText("$zipPath.sha256", "$($zipHash.Hash.ToLowerInvariant())  $packageName.zip" + [Environment]::NewLine)
Write-Output "Script directory: $packageDirectory"
Write-Output "Script ZIP: $zipPath"
