[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$projectFile = Join-Path $projectRoot 'src\CodexRepair.Portable\CodexRepair.Portable.csproj'
$version = (Get-Content -LiteralPath (Join-Path $projectRoot 'VERSION') -Raw).Trim()
$distRoot = Join-Path $projectRoot 'dist'
$packageName = "CodexRepair-v$version-win-x64"
$packageDirectory = Join-Path $distRoot $packageName
$zipPath = Join-Path $distRoot "$packageName.zip"
$temporaryPublish = Join-Path $projectRoot (".portable-publish-" + [guid]::NewGuid().ToString('N'))

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'The build machine needs a .NET 8 SDK. End users do not need it.'
}
foreach ($required in @('LICENSE', 'THIRD-PARTY-NOTICES.txt', 'licenses\dotnet-LICENSE.txt', 'licenses\dotnet-THIRD-PARTY-NOTICES.txt', 'licenses\efcore-LICENSE.txt', 'licenses\SQLitePCLRaw-LICENSE.txt', 'licenses\SQLite-PUBLIC-DOMAIN.txt')) {
    if (-not (Test-Path -LiteralPath (Join-Path $projectRoot $required) -PathType Leaf)) {
        throw "Required release notice is missing: $required"
    }
}
if ((Test-Path -LiteralPath $packageDirectory) -or (Test-Path -LiteralPath $zipPath)) {
    if (-not $Force) { throw "Release $packageName exists. Use -Force to replace only this version." }
    $normalizedDist = [IO.Path]::GetFullPath($distRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    foreach ($target in @($packageDirectory, $zipPath)) {
        $normalizedTarget = [IO.Path]::GetFullPath($target)
        if (-not $normalizedTarget.StartsWith($normalizedDist, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to replace a path outside dist: $normalizedTarget"
        }
        if (Test-Path -LiteralPath $normalizedTarget) { Remove-Item -LiteralPath $normalizedTarget -Recurse -Force }
    }
}

try {
    $null = New-Item -ItemType Directory -Path $distRoot -Force
    # Restore is intentional: a clean clone must not depend on a developer's obj/cache.
    dotnet publish $projectFile -c Release -r win-x64 --self-contained true -p:DebugType=None -p:DebugSymbols=false -o $temporaryPublish
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE." }
    foreach ($required in @('CodexRepair.exe', 'CodexRepair.dll', 'coreclr.dll', 'e_sqlite3.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $temporaryPublish $required) -PathType Leaf)) {
            throw "Self-contained application file is missing: $required"
        }
    }
    $appDirectory = Join-Path $packageDirectory 'app'
    $null = New-Item -ItemType Directory -Path $appDirectory -Force
    Get-ChildItem -LiteralPath $temporaryPublish -Force | Copy-Item -Destination $appDirectory -Recurse
    Copy-Item -LiteralPath (Join-Path $projectRoot 'portable\Codex Repair.cmd') -Destination $packageDirectory
    foreach ($name in @('VERSION', 'PORTABLE_README.txt', 'LICENSE', 'THIRD-PARTY-NOTICES.txt')) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination $packageDirectory
    }
    Copy-Item -LiteralPath (Join-Path $projectRoot 'licenses') -Destination $packageDirectory -Recurse
    $forbidden = @(Get-ChildItem -LiteralPath $packageDirectory -Recurse -Force | Where-Object {
        $_.Name -in @('backups', 'sessions', '.env') -or $_.Extension -in @('.jsonl', '.sqlite', '.bak', '.pdb')
    })
    if ($forbidden.Count) { throw 'Release contains forbidden session, backup, or debug content.' }

    # A self-contained executable must work without discovering a global runtime.
    $previousRoot = $env:DOTNET_ROOT
    $previousRootX64 = $env:DOTNET_ROOT_X64
    try {
        $env:DOTNET_ROOT = Join-Path $temporaryPublish 'no-global-runtime'
        $env:DOTNET_ROOT_X64 = $env:DOTNET_ROOT
        $process = Start-Process -FilePath (Join-Path $appDirectory 'CodexRepair.exe') -ArgumentList '--self-test' -WorkingDirectory $projectRoot -WindowStyle Hidden -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "Packaged self-test failed with exit code $($process.ExitCode)." }
    }
    finally {
        $env:DOTNET_ROOT = $previousRoot
        $env:DOTNET_ROOT_X64 = $previousRootX64
    }

    $hashLines = foreach ($file in Get-ChildItem -LiteralPath $packageDirectory -File -Recurse | Sort-Object FullName) {
        $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
        "$($hash.Hash.ToLowerInvariant())  $($file.FullName.Substring($packageDirectory.Length + 1).Replace('\', '/'))"
    }
    [IO.File]::WriteAllText((Join-Path $packageDirectory 'SHA256SUMS.txt'), (($hashLines -join [Environment]::NewLine) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Compress-Archive -LiteralPath $packageDirectory -DestinationPath $zipPath -CompressionLevel Optimal
    $zipHash = Get-FileHash -LiteralPath $zipPath -Algorithm SHA256
    [IO.File]::WriteAllText("$zipPath.sha256", "$($zipHash.Hash.ToLowerInvariant())  $packageName.zip" + [Environment]::NewLine)
    Write-Output "Portable ZIP: $zipPath"
}
finally {
    $normalizedTemp = [IO.Path]::GetFullPath($temporaryPublish)
    $normalizedProject = [IO.Path]::GetFullPath($projectRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($normalizedTemp.StartsWith($normalizedProject, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $normalizedTemp -Leaf).StartsWith('.portable-publish-') -and (Test-Path -LiteralPath $normalizedTemp)) {
        Remove-Item -LiteralPath $normalizedTemp -Recurse -Force
    }
}
