# Shared by repair and restore. Readers are allowed; existing and new writers are refused.
function Open-SessionWriteGuard {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$ExpectedBytes
    )

    $share = [IO.FileShare]::Read -bor [IO.FileShare]::Delete
    $guard = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $expected = [Convert]::ToBase64String($sha.ComputeHash($ExpectedBytes))
            $current = [Convert]::ToBase64String($sha.ComputeHash($guard))
        }
        finally { $sha.Dispose() }
        if ($current -ne $expected) {
            throw 'Session changed since inspection. Close the task and rescan; no repair was made.'
        }
        return $guard
    }
    catch {
        $guard.Dispose()
        throw
    }
}

function Complete-SessionReplacement {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TemporaryPath,
        [Parameter(Mandatory = $true)][datetime]$LastWriteTimeUtc
    )

    [IO.File]::SetLastWriteTimeUtc($TemporaryPath, $LastWriteTimeUtc)
    $swapPath = $TemporaryPath + '.swap'
    [IO.File]::Replace($TemporaryPath, $Path, $swapPath)
    # A cleanup error must not hide a successful replacement from the caller.
    # If Replace fails, leave any swap file intact for recovery.
    Remove-Item -LiteralPath $swapPath -Force -ErrorAction SilentlyContinue
}
