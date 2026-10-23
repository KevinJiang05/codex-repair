[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PlanPath
)

$ErrorActionPreference = 'Stop'
$repairScript = Join-Path $PSScriptRoot 'repair-core.ps1'
$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
$batchDirectory = [IO.Path]::GetFullPath([string]$plan.batch_directory)
$backupRoot = [IO.Path]::GetFullPath([string]$plan.backup_root)
$progressPath = Join-Path $batchDirectory 'progress.log'
$reportPath = Join-Path $batchDirectory 'batch-report.json'
$utf8 = [Text.UTF8Encoding]::new($false)

if (-not $batchDirectory.StartsWith(
    $backupRoot + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'Batch directory must be inside BackupRoot.'
}
if (-not (Test-Path -LiteralPath $repairScript -PathType Leaf)) {
    throw "Repair core not found: $repairScript"
}

function Write-ProgressLine {
    param([Parameter(Mandatory = $true)][string]$Text)

    [IO.File]::AppendAllText(
        $progressPath,
        "$(Get-Date -Format 'HH:mm:ss')  $Text`r`n",
        $utf8
    )
}

function Write-BatchReport {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[object]]$Results,
        [Parameter(Mandatory = $true)][int]$Total
    )

    $success = @($Results | Where-Object status -eq 'success').Count
    $failed = @($Results | Where-Object status -eq 'failed').Count
    $report = [ordered]@{
        version = 3
        status = $Status
        created_at = [string]$plan.created_at
        updated_at = (Get-Date).ToString('o')
        worker_pid = $PID
        target_provider = [string]$plan.target_provider
        selected_count = $Total
        completed_count = $Results.Count
        success_count = $success
        failed_count = $failed
        results = $Results
    }
    $temporaryReport = "$reportPath.tmp"
    [IO.File]::WriteAllText(
        $temporaryReport,
        ($report | ConvertTo-Json -Depth 8),
        $utf8
    )
    if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
        $swapBackup = "$reportPath.swap"
        [IO.File]::Replace($temporaryReport, $reportPath, $swapBackup)
        Remove-Item -LiteralPath $swapBackup -Force -ErrorAction SilentlyContinue
    }
    else {
        [IO.File]::Move($temporaryReport, $reportPath)
    }
}

$items = @($plan.items)
$results = [Collections.Generic.List[object]]::new()
Write-ProgressLine "后台修复开始，共 $($items.Count) 个任务。"
Write-BatchReport -Status 'running' -Results $results -Total $items.Count

foreach ($item in $items) {
    $sessionId = [string]$item.session_id
    $mode = if ([bool]$item.advanced) { 'advanced' } else { 'standard' }
    Write-ProgressLine "开始 $sessionId（$mode）"
    try {
        $parameters = @{
            SessionId = $sessionId
            TargetProvider = [string]$plan.target_provider
            CodexHome = [string]$plan.codex_home
            BackupRoot = $backupRoot
            BatchBackupDirectory = $batchDirectory
        }
        if ([bool]$item.advanced) {
            $parameters.RewriteRuntimeProvider = $true
        }
        $messages = @(& $repairScript @parameters 2>&1)
        $results.Add([pscustomobject]@{
            session_id = $sessionId
            status = 'success'
            repair_mode = $mode
            error = $null
        })
        Write-ProgressLine "完成 $sessionId"
        foreach ($message in $messages) {
            Write-ProgressLine "  $message"
        }
    }
    catch {
        $results.Add([pscustomobject]@{
            session_id = $sessionId
            status = 'failed'
            repair_mode = $mode
            error = $_.Exception.Message
        })
        Write-ProgressLine "失败 $sessionId：$($_.Exception.Message)"
    }
    Write-BatchReport -Status 'running' -Results $results -Total $items.Count
}

Write-BatchReport -Status 'completed' -Results $results -Total $items.Count
Write-ProgressLine "后台修复结束：成功 $(@($results | Where-Object status -eq 'success').Count)，失败 $(@($results | Where-Object status -eq 'failed').Count)。"
