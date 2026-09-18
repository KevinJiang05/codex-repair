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

if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
    throw "Portable project not found: $projectFile"
}
$dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnetCommand) {
    throw 'The build machine needs a .NET 8 SDK. End users do not need it.'
}
$dotnetRoot = Split-Path -Parent $dotnetCommand.Source
$coreRoot = Join-Path $dotnetRoot 'shared\Microsoft.NETCore.App'
$desktopRoot = Join-Path $dotnetRoot 'shared\Microsoft.WindowsDesktop.App'
$fxrRoot = Join-Path $dotnetRoot 'host\fxr'
$coreVersions = @(Get-ChildItem -LiteralPath $coreRoot -Directory |
    Where-Object Name -Match '^8\.0\.\d+$' | ForEach-Object Name)
$desktopVersions = @(Get-ChildItem -LiteralPath $desktopRoot -Directory |
    Where-Object Name -Match '^8\.0\.\d+$' | ForEach-Object Name)
$fxrVersions = @(Get-ChildItem -LiteralPath $fxrRoot -Directory |
    Where-Object Name -Match '^8\.0\.\d+$' | ForEach-Object Name)
$runtimeVersion = @($coreVersions | Where-Object {
    $_ -in $desktopVersions -and $_ -in $fxrVersions
} | Sort-Object { [version]$_ } -Descending | Select-Object -First 1)
if ($runtimeVersion.Count -ne 1) {
    throw 'No complete installed .NET 8 desktop runtime was found on the build machine.'
}
$runtimeVersion = [string]$runtimeVersion[0]

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

try {
    $null = New-Item -ItemType Directory -Path $distRoot -Force
    dotnet publish $projectFile -c Release --no-self-contained --no-restore `
        -p:UseAppHost=false -p:DebugType=None -p:DebugSymbols=false -o $temporaryPublish
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed with exit code $LASTEXITCODE."
    }
    foreach ($required in @('CodexRepair.dll', 'CodexRepair.deps.json', 'CodexRepair.runtimeconfig.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $temporaryPublish $required) -PathType Leaf)) {
            throw "Published application file is missing: $required"
        }
    }

    $appDirectory = Join-Path $packageDirectory 'app'
    $runtimeDirectory = Join-Path $packageDirectory 'runtime'
    $null = New-Item -ItemType Directory -Path $appDirectory -Force
    $null = New-Item -ItemType Directory -Path $runtimeDirectory -Force
    Get-ChildItem -LiteralPath $temporaryPublish -File |
        Where-Object Extension -Ne '.pdb' | Copy-Item -Destination $appDirectory
    $nativeSource = Join-Path $temporaryPublish 'runtimes\win-x64\native'
    if (-not (Test-Path -LiteralPath $nativeSource -PathType Container)) {
        throw 'Published win-x64 SQLite native library is missing.'
    }
    $nativeDestination = Join-Path $appDirectory 'runtimes\win-x64\native'
    $null = New-Item -ItemType Directory -Path $nativeDestination -Force
    Get-ChildItem -LiteralPath $nativeSource -File | Copy-Item -Destination $nativeDestination

    Copy-Item -LiteralPath (Join-Path $dotnetRoot 'dotnet.exe') -Destination $runtimeDirectory
    $fxrDestination = Join-Path $runtimeDirectory "host\fxr\$runtimeVersion"
    $coreDestination = Join-Path $runtimeDirectory "shared\Microsoft.NETCore.App\$runtimeVersion"
    $desktopDestination = Join-Path $runtimeDirectory "shared\Microsoft.WindowsDesktop.App\$runtimeVersion"
    $null = New-Item -ItemType Directory -Path $fxrDestination -Force
    $null = New-Item -ItemType Directory -Path $coreDestination -Force
    $null = New-Item -ItemType Directory -Path $desktopDestination -Force
    Get-ChildItem -LiteralPath (Join-Path $fxrRoot $runtimeVersion) -Force | Copy-Item -Destination $fxrDestination -Recurse
    Get-ChildItem -LiteralPath (Join-Path $coreRoot $runtimeVersion) -Force | Copy-Item -Destination $coreDestination -Recurse
    Get-ChildItem -LiteralPath (Join-Path $desktopRoot $runtimeVersion) -Force | Copy-Item -Destination $desktopDestination -Recurse

    Copy-Item -LiteralPath (Join-Path $projectRoot 'portable\Codex Repair.cmd') -Destination $packageDirectory
    Copy-Item -LiteralPath (Join-Path $projectRoot 'VERSION') -Destination $packageDirectory
    Copy-Item -LiteralPath (Join-Path $projectRoot 'PORTABLE_README.txt') -Destination $packageDirectory
    Copy-Item -LiteralPath (Join-Path $projectRoot 'THIRD-PARTY-NOTICES.txt') -Destination $packageDirectory
    foreach ($notice in @('LICENSE.txt', 'ThirdPartyNotices.txt')) {
        $source = Join-Path $dotnetRoot $notice
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $packageDirectory "DOTNET-$notice")
        }
    }

    $forbidden = @(Get-ChildItem -LiteralPath $packageDirectory -Recurse -Force |
        Where-Object { $_.Name -in @('backups', 'sessions') -or $_.Extension -in @('.jsonl', '.sqlite', '.bak') })
    if ($forbidden.Count -gt 0) {
        throw 'Release validation found forbidden session or backup content.'
    }

    $hashTargets = @(
        (Join-Path $packageDirectory 'app\CodexRepair.dll'),
        (Join-Path $packageDirectory 'runtime\dotnet.exe')
    )
    $hashLines = foreach ($hashTarget in $hashTargets) {
        $hash = Get-FileHash -LiteralPath $hashTarget -Algorithm SHA256
        "$($hash.Hash.ToLowerInvariant())  $($hashTarget.Substring($packageDirectory.Length + 1).Replace('\', '/'))"
    }
    [IO.File]::WriteAllText(
        (Join-Path $packageDirectory 'SHA256SUMS.txt'),
        (($hashLines -join "`r`n") + "`r`n"),
        [Text.UTF8Encoding]::new($false)
    )

    $previousDotnetRoot = $env:DOTNET_ROOT
    $previousDotnetRootX64 = $env:DOTNET_ROOT_X64
    $previousMultilevel = $env:DOTNET_MULTILEVEL_LOOKUP
    try {
        $env:DOTNET_ROOT = $runtimeDirectory
        $env:DOTNET_ROOT_X64 = $runtimeDirectory
        $env:DOTNET_MULTILEVEL_LOOKUP = '0'
        & (Join-Path $runtimeDirectory 'dotnet.exe') (Join-Path $appDirectory 'CodexRepair.dll') --self-test
        if ($LASTEXITCODE -ne 0) {
            throw "Packaged application self-test failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        $env:DOTNET_ROOT = $previousDotnetRoot
        $env:DOTNET_ROOT_X64 = $previousDotnetRootX64
        $env:DOTNET_MULTILEVEL_LOOKUP = $previousMultilevel
    }

    Compress-Archive -LiteralPath $packageDirectory -DestinationPath $zipPath -CompressionLevel Optimal
    Write-Output "Bundled .NET runtime: $runtimeVersion"
    Write-Output "Portable directory: $packageDirectory"
    Write-Output "Portable ZIP: $zipPath"
}
finally {
    $normalizedTemp = [IO.Path]::GetFullPath($temporaryPublish)
    $normalizedProject = [IO.Path]::GetFullPath($projectRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    if ($normalizedTemp.StartsWith($normalizedProject, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $normalizedTemp -Leaf).StartsWith('.portable-publish-') -and
        (Test-Path -LiteralPath $normalizedTemp)) {
        Remove-Item -LiteralPath $normalizedTemp -Recurse -Force
    }
}
