[CmdletBinding()]
param(
    [switch]$ScanOnly,
    [switch]$SummaryOnly,
    [datetime]$FromDate = (Get-Date).Date.AddDays(-6),
    [datetime]$ToDate = (Get-Date).Date,
    [switch]$AllDates,
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex')
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $CodexHome 'config.toml'
$repairScript = Join-Path $PSScriptRoot 'repair-core.ps1'
$batchRepairScript = Join-Path $PSScriptRoot 'repair-batch.ps1'
$restoreScript = Join-Path $PSScriptRoot 'restore-core.ps1'
$backupRoot = Join-Path $projectRoot 'backups'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Codex config not found: $configPath"
}
if (-not (Test-Path -LiteralPath $repairScript -PathType Leaf)) {
    throw "Repair script not found: $repairScript"
}
if (-not (Test-Path -LiteralPath $batchRepairScript -PathType Leaf)) {
    throw "Batch repair script not found: $batchRepairScript"
}
if (-not (Test-Path -LiteralPath $restoreScript -PathType Leaf)) {
    throw "Restore script not found: $restoreScript"
}

$pythonCommand = Get-Command py -ErrorAction SilentlyContinue
$pythonArguments = @('-3')
if (-not $pythonCommand) {
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    $pythonArguments = @()
}
if (-not $pythonCommand) {
    throw 'Python 3 is required to scan the Codex state database.'
}

function Get-CurrentProvider {
    $configText = [IO.File]::ReadAllText($configPath)
    $match = [regex]::Match(
        $configText,
        '(?m)^\s*model_provider\s*=\s*"([A-Za-z0-9_-]+)"\s*$'
    )
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return 'openai'
}

$scannerCode = @'
import base64
import datetime
import glob
import json
import os
import re
import sqlite3
import sys

sys.stdout.reconfigure(encoding="utf-8")
codex_home, target, start_text, end_text = sys.argv[1:5]
start_epoch = int(start_text)
end_epoch = int(end_text)
database_pattern = os.path.join(codex_home, "state_*.sqlite")
database_paths = [
    path for path in glob.glob(database_pattern)
    if re.search(r"state_[0-9]+\.sqlite$", os.path.basename(path))
]

results = []
for database in database_paths:
    uri = "file:" + database.replace("\\", "/") + "?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=10)
    try:
        rows = connection.execute(
            "select id, rollout_path, created_at, model_provider, title, archived "
            "from threads where created_at >= ? and created_at < ? "
            "order by created_at desc",
            (start_epoch, end_epoch),
        ).fetchall()
    finally:
        connection.close()

    for session_id, rollout_path, created_at, database_provider, title, archived in rows:
        file_provider = None
        file_state = "ok"
        runtime_providers = []
        try:
            with open(rollout_path, "r", encoding="utf-8") as stream:
                first = json.loads(stream.readline())
                for line in stream:
                    if "thread_settings_applied" not in line:
                        continue
                    record = json.loads(line)
                    payload = record.get("payload", {})
                    if payload.get("type") != "thread_settings_applied":
                        continue
                    runtime_provider = payload.get("thread_settings", {}).get(
                        "model_provider_id"
                    )
                    if runtime_provider:
                        runtime_providers.append(runtime_provider)
            if first.get("type") != "session_meta":
                file_state = "invalid metadata"
            else:
                file_provider = first.get("payload", {}).get("model_provider")
                if not file_provider:
                    file_state = "provider missing"
        except FileNotFoundError:
            file_state = "file missing"
        except Exception:
            file_state = "file unreadable"

        runtime_unique = sorted(set(runtime_providers))
        runtime_latest = runtime_providers[-1] if runtime_providers else None
        runtime_conflict = runtime_latest is not None and runtime_latest != target
        needs_repair = (
            database_provider != target
            or file_provider != target
            or file_state != "ok"
            or runtime_conflict
        )
        repairable = needs_repair and file_state == "ok" and not runtime_conflict
        advanced_repairable = needs_repair and file_state == "ok" and runtime_conflict
        if not needs_repair:
            classification = "normal"
        elif repairable:
            classification = "auto"
        elif runtime_conflict:
            classification = "runtime_conflict"
        else:
            classification = "blocked"
        results.append({
            "id": session_id,
            "created": datetime.datetime.fromtimestamp(created_at).strftime("%Y-%m-%d %H:%M"),
            "database_provider": database_provider or "<missing>",
            "file_provider": file_provider or "<missing>",
            "file_state": file_state,
            "runtime_provider": runtime_latest or "<none>",
            "runtime_provider_history": ", ".join(runtime_unique) if runtime_unique else "<none>",
            "runtime_conflict": runtime_conflict,
            "needs_repair": needs_repair,
            "repairable": repairable,
            "advanced_repairable": advanced_repairable,
            "classification": classification,
            "archived": bool(archived),
            "title": title or "",
            "database": database,
        })

payload = json.dumps(results, ensure_ascii=False).encode("utf-8")
print(base64.b64encode(payload).decode("ascii"))
'@

function Get-ScanResults {
    param(
        [Parameter(Mandatory = $true)][datetime]$Start,
        [Parameter(Mandatory = $true)][datetime]$End,
        [Parameter(Mandatory = $true)][bool]$UseAllDates,
        [Parameter(Mandatory = $true)][string]$TargetProvider
    )

    if ($UseAllDates) {
        $startEpoch = 0
        $endEpoch = [Int64]::MaxValue
    }
    else {
        if ($End.Date -lt $Start.Date) {
            throw '结束日期不能早于开始日期。'
        }
        $startEpoch = ([DateTimeOffset]$Start.Date).ToUnixTimeSeconds()
        $endEpoch = ([DateTimeOffset]$End.Date.AddDays(1)).ToUnixTimeSeconds()
    }

    $output = & $pythonCommand.Source @pythonArguments -c $scannerCode `
        $CodexHome $TargetProvider $startEpoch $endEpoch
    if ($LASTEXITCODE -ne 0) {
        throw "Scanner failed with exit code $LASTEXITCODE."
    }
    if (-not $output) {
        return @()
    }
    $jsonBytes = [Convert]::FromBase64String(($output -join '').Trim())
    $jsonText = [Text.Encoding]::UTF8.GetString($jsonBytes)
    return @($jsonText | ConvertFrom-Json)
}

if ($ScanOnly) {
    $provider = Get-CurrentProvider
    $results = Get-ScanResults -Start $FromDate -End $ToDate `
        -UseAllDates $AllDates.IsPresent -TargetProvider $provider
    if (-not $SummaryOnly) {
        $results |
            Select-Object id, created, database_provider, file_provider,
                runtime_provider, classification, archived, title |
            Format-Table -AutoSize
    }
    $needsCount = @($results | Where-Object needs_repair).Count
    $autoCount = @($results | Where-Object repairable).Count
    $advancedCount = @($results | Where-Object advanced_repairable).Count
    $blockedCount = $needsCount - $autoCount - $advancedCount
    Write-Output "Scanned: $($results.Count); needs repair: $needsCount; standard: $autoCount; advanced: $advancedCount; blocked: $blockedCount; target provider: $provider"
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object Windows.Forms.Form
$form.Text = 'Codex 历史任务 Provider 批量修复'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(1220, 760)
$form.MinimumSize = New-Object Drawing.Size(980, 620)
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)

$providerLabel = New-Object Windows.Forms.Label
$providerLabel.Location = New-Object Drawing.Point(16, 18)
$providerLabel.AutoSize = $true
$form.Controls.Add($providerLabel)

$allDatesCheck = New-Object Windows.Forms.CheckBox
$allDatesCheck.Text = '全部日期'
$allDatesCheck.Location = New-Object Drawing.Point(290, 15)
$allDatesCheck.AutoSize = $true
$form.Controls.Add($allDatesCheck)

$fromLabel = New-Object Windows.Forms.Label
$fromLabel.Text = '开始：'
$fromLabel.Location = New-Object Drawing.Point(390, 18)
$fromLabel.AutoSize = $true
$form.Controls.Add($fromLabel)

$fromPicker = New-Object Windows.Forms.DateTimePicker
$fromPicker.Format = 'Short'
$fromPicker.Value = $FromDate
$fromPicker.Location = New-Object Drawing.Point(440, 14)
$fromPicker.Width = 120
$form.Controls.Add($fromPicker)

$toLabel = New-Object Windows.Forms.Label
$toLabel.Text = '结束：'
$toLabel.Location = New-Object Drawing.Point(575, 18)
$toLabel.AutoSize = $true
$form.Controls.Add($toLabel)

$toPicker = New-Object Windows.Forms.DateTimePicker
$toPicker.Format = 'Short'
$toPicker.Value = $ToDate
$toPicker.Location = New-Object Drawing.Point(625, 14)
$toPicker.Width = 120
$form.Controls.Add($toPicker)

$onlyProblemsCheck = New-Object Windows.Forms.CheckBox
$onlyProblemsCheck.Text = '仅显示需要修复'
$onlyProblemsCheck.Checked = $true
$onlyProblemsCheck.Location = New-Object Drawing.Point(765, 15)
$onlyProblemsCheck.AutoSize = $true
$form.Controls.Add($onlyProblemsCheck)

$scanButton = New-Object Windows.Forms.Button
$scanButton.Text = '扫描'
$scanButton.Location = New-Object Drawing.Point(930, 11)
$scanButton.Size = New-Object Drawing.Size(90, 30)
$form.Controls.Add($scanButton)

$list = New-Object Windows.Forms.ListView
$list.Location = New-Object Drawing.Point(16, 54)
$list.Size = New-Object Drawing.Size(1170, 500)
$list.Anchor = 'Top,Bottom,Left,Right'
$list.View = 'Details'
$list.FullRowSelect = $true
$list.GridLines = $true
$list.CheckBoxes = $true
$null = $list.Columns.Add('任务 ID', 275)
$null = $list.Columns.Add('创建时间', 125)
$null = $list.Columns.Add('数据库', 75)
$null = $list.Columns.Add('JSONL', 75)
$null = $list.Columns.Add('运行时', 85)
$null = $list.Columns.Add('状态', 105)
$null = $list.Columns.Add('归档', 55)
$null = $list.Columns.Add('标题', 345)
$form.Controls.Add($list)

$selectProblemsButton = New-Object Windows.Forms.Button
$selectProblemsButton.Text = '勾选可自动修复'
$selectProblemsButton.Location = New-Object Drawing.Point(16, 568)
$selectProblemsButton.Size = New-Object Drawing.Size(125, 32)
$selectProblemsButton.Anchor = 'Bottom,Left'
$form.Controls.Add($selectProblemsButton)

$clearButton = New-Object Windows.Forms.Button
$clearButton.Text = '清除勾选'
$clearButton.Location = New-Object Drawing.Point(150, 568)
$clearButton.Size = New-Object Drawing.Size(100, 32)
$clearButton.Anchor = 'Bottom,Left'
$form.Controls.Add($clearButton)

$repairButton = New-Object Windows.Forms.Button
$repairButton.Text = '修复勾选项'
$repairButton.Location = New-Object Drawing.Point(260, 568)
$repairButton.Size = New-Object Drawing.Size(120, 32)
$repairButton.Anchor = 'Bottom,Left'
$form.Controls.Add($repairButton)

$advancedCheck = New-Object Windows.Forms.CheckBox
$advancedCheck.Text = '启用黄色高级修复'
$advancedCheck.Location = New-Object Drawing.Point(395, 575)
$advancedCheck.AutoSize = $true
$advancedCheck.Anchor = 'Bottom,Left'
$form.Controls.Add($advancedCheck)

$restoreButton = New-Object Windows.Forms.Button
$restoreButton.Text = '恢复备份'
$restoreButton.Location = New-Object Drawing.Point(570, 568)
$restoreButton.Size = New-Object Drawing.Size(105, 32)
$restoreButton.Anchor = 'Bottom,Left'
$form.Controls.Add($restoreButton)

$statusLabel = New-Object Windows.Forms.Label
$statusLabel.Location = New-Object Drawing.Point(690, 576)
$statusLabel.AutoSize = $true
$statusLabel.Anchor = 'Bottom,Left'
$form.Controls.Add($statusLabel)

$logBox = New-Object Windows.Forms.TextBox
$logBox.Location = New-Object Drawing.Point(16, 612)
$logBox.Size = New-Object Drawing.Size(1170, 95)
$logBox.Anchor = 'Bottom,Left,Right'
$logBox.Multiline = $true
$logBox.ScrollBars = 'Vertical'
$logBox.ReadOnly = $true
$form.Controls.Add($logBox)

$script:allResults = @()
$script:scannedProvider = $null
$script:repairProcess = $null
$script:repairBatchDirectory = $null
$script:progressLineCount = 0

function Add-LogLine {
    param([string]$Text)
    $logBox.AppendText("$(Get-Date -Format 'HH:mm:ss')  $Text`r`n")
}

$repairTimer = New-Object Windows.Forms.Timer
$repairTimer.Interval = 500
$repairTimer.Add_Tick({
    if (-not $script:repairProcess) {
        $repairTimer.Stop()
        return
    }

    $progressPath = Join-Path $script:repairBatchDirectory 'progress.log'
    if (Test-Path -LiteralPath $progressPath -PathType Leaf) {
        try {
            $progressLines = [IO.File]::ReadAllLines($progressPath)
            for ($index = $script:progressLineCount; $index -lt $progressLines.Count; $index++) {
                $logBox.AppendText("$($progressLines[$index])`r`n")
            }
            $script:progressLineCount = $progressLines.Count
        }
        catch [IO.IOException] {
            # The worker may be appending at this instant; retry on the next timer tick.
        }
    }

    $liveReportPath = Join-Path $script:repairBatchDirectory 'batch-report.json'
    if (Test-Path -LiteralPath $liveReportPath -PathType Leaf) {
        try {
            $liveReport = Get-Content -LiteralPath $liveReportPath -Raw |
                ConvertFrom-Json -Depth 20
            $statusLabel.Text = "后台修复中：$($liveReport.completed_count) / $($liveReport.selected_count)；失败 $($liveReport.failed_count)"
        }
        catch {
            # The report is replaced atomically; retry if it changed between checks.
        }
    }

    if (-not $script:repairProcess.HasExited) {
        return
    }

    $repairTimer.Stop()
    $exitCode = $script:repairProcess.ExitCode
    $script:repairProcess.Dispose()
    $script:repairProcess = $null
    $repairButton.Enabled = $true
    $scanButton.Enabled = $true
    $restoreButton.Enabled = $true
    $advancedCheck.Enabled = $true

    $reportPath = Join-Path $script:repairBatchDirectory 'batch-report.json'
    if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
        try {
            $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 20
            $statusLabel.Text = "后台处理完成：成功 $($report.success_count)，失败 $($report.failed_count)；请重新扫描"
            [Windows.Forms.MessageBox]::Show(
                "后台批量处理完成：成功 $($report.success_count)，失败 $($report.failed_count)。`r`n" +
                "备份与报告：$script:repairBatchDirectory`r`n" +
                "请点击扫描按钮刷新列表，并重新打开相关 Codex 任务。",
                '处理完成', 'OK', $(if ($report.failed_count) { 'Warning' } else { 'Information' })
            ) | Out-Null
        }
        catch {
            Add-LogLine "读取批次报告失败：$($_.Exception.Message)"
        }
    }
    else {
        $statusLabel.Text = "后台进程异常结束（退出码 $exitCode）"
        [Windows.Forms.MessageBox]::Show(
            "后台修复进程退出，但没有生成批次报告。退出码：$exitCode`r`n" +
            "请查看：$script:repairBatchDirectory",
            '后台修复异常', 'OK', 'Error'
        ) | Out-Null
    }
})

function Show-Results {
    $list.BeginUpdate()
    try {
        $list.Items.Clear()
        $visible = if ($onlyProblemsCheck.Checked) {
            @($script:allResults | Where-Object needs_repair)
        }
        else {
            @($script:allResults)
        }
        foreach ($row in $visible) {
            $state = switch ([string]$row.classification) {
                'auto' { '可自动修复' }
                'runtime_conflict' { '高级可修复' }
                'blocked' { '无法自动修复' }
                default { '正常' }
            }
            if ($row.file_state -ne 'ok') {
                $state = $row.file_state
            }
            $item = New-Object Windows.Forms.ListViewItem([string]$row.id)
            $null = $item.SubItems.Add([string]$row.created)
            $null = $item.SubItems.Add([string]$row.database_provider)
            $null = $item.SubItems.Add([string]$row.file_provider)
            $null = $item.SubItems.Add([string]$row.runtime_provider)
            $null = $item.SubItems.Add($state)
            $null = $item.SubItems.Add($(if ($row.archived) { '是' } else { '否' }))
            $null = $item.SubItems.Add([string]$row.title)
            $item.Tag = $row
            if ($row.repairable) {
                $item.BackColor = [Drawing.Color]::MistyRose
            }
            elseif ($row.needs_repair) {
                $item.BackColor = [Drawing.Color]::LightYellow
            }
            $null = $list.Items.Add($item)
        }
        $problemCount = @($script:allResults | Where-Object needs_repair).Count
        $autoCount = @($script:allResults | Where-Object repairable).Count
        $advancedCount = @($script:allResults | Where-Object advanced_repairable).Count
        $blockedCount = $problemCount - $autoCount - $advancedCount
        $statusLabel.Text = "扫描 $($script:allResults.Count)；普通 $autoCount；高级 $advancedCount；阻止 $blockedCount；显示 $($visible.Count)"
    }
    finally {
        $list.EndUpdate()
    }
}

$allDatesCheck.Add_CheckedChanged({
    $fromPicker.Enabled = -not $allDatesCheck.Checked
    $toPicker.Enabled = -not $allDatesCheck.Checked
})

$onlyProblemsCheck.Add_CheckedChanged({ Show-Results })

$scanButton.Add_Click({
    try {
        $form.UseWaitCursor = $true
        $scanButton.Enabled = $false
        $script:scannedProvider = Get-CurrentProvider
        $providerLabel.Text = "目标 provider：$script:scannedProvider"
        $script:allResults = Get-ScanResults `
            -Start $fromPicker.Value.Date `
            -End $toPicker.Value.Date `
            -UseAllDates $allDatesCheck.Checked `
            -TargetProvider $script:scannedProvider
        Show-Results
        Add-LogLine "扫描完成；未写入任何文件。"
    }
    catch {
        [Windows.Forms.MessageBox]::Show(
            $_.Exception.Message, '扫描失败', 'OK', 'Error'
        ) | Out-Null
        Add-LogLine "扫描失败：$($_.Exception.Message)"
    }
    finally {
        $scanButton.Enabled = $true
        $form.UseWaitCursor = $false
    }
})

$selectProblemsButton.Add_Click({
    foreach ($item in $list.Items) {
        $item.Checked = [bool]$item.Tag.repairable -or
            ($advancedCheck.Checked -and [bool]$item.Tag.advanced_repairable)
    }
})

$clearButton.Add_Click({
    foreach ($item in $list.Items) {
        $item.Checked = $false
    }
})

$repairButton.Add_Click({
    $selected = @($list.Items | Where-Object Checked | ForEach-Object Tag)
    if ($selected.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show(
            '请先勾选至少一个需要修复的任务。', '没有选择', 'OK', 'Information'
        ) | Out-Null
        return
    }

    $unsafeSelected = @($selected | Where-Object {
        -not $_.repairable -and
        -not ($advancedCheck.Checked -and $_.advanced_repairable)
    })
    if ($unsafeSelected.Count -gt 0) {
        [Windows.Forms.MessageBox]::Show(
            "选中的任务中有 $($unsafeSelected.Count) 个无法按当前模式修复。`r`n" +
            "黄色运行时冲突需要先启用高级修复；文件异常仍会被阻止。",
            '包含需谨慎任务', 'OK', 'Warning'
        ) | Out-Null
        return
    }

    $currentProvider = Get-CurrentProvider
    if ($currentProvider -ne $script:scannedProvider) {
        [Windows.Forms.MessageBox]::Show(
            "当前 provider 已从 '$script:scannedProvider' 变为 '$currentProvider'。请重新扫描后再修复。",
            '配置已变化', 'OK', 'Warning'
        ) | Out-Null
        return
    }

    $advancedSelected = @($selected | Where-Object advanced_repairable)

    $answer = [Windows.Forms.MessageBox]::Show(
        "将把 $($selected.Count) 个任务同步到 provider '$currentProvider'，其中高级修复 $($advancedSelected.Count) 个。`r`n" +
        "每个 JSONL 修改前都会备份；每个状态数据库本批只备份一次。`r`n" +
        "备份统一位于 $backupRoot。`r`n" +
        "是否继续？",
        '确认批量修复', 'YesNo', 'Warning'
    )
    if ($answer -ne 'Yes') {
        return
    }
    if ($advancedSelected.Count -gt 0) {
        $advancedAnswer = [Windows.Forms.MessageBox]::Show(
            "高级修复会改写每个黄色任务最后一条生效的运行时 provider 记录。`r`n" +
            "不会改写更早的历史记录；写入前会完整备份 JSONL。`r`n`r`n" +
            "确定继续修复 $($advancedSelected.Count) 个黄色任务吗？",
            '再次确认高级修复', 'YesNo', 'Warning'
        )
        if ($advancedAnswer -ne 'Yes') {
            return
        }
    }

    $batchTimestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $batchDirectory = Join-Path $backupRoot "$batchTimestamp-batch-$($selected.Count)"
    try {
        $null = New-Item -ItemType Directory -Path $batchDirectory -Force
        $batchPlan = [ordered]@{
            version = 1
            created_at = (Get-Date).ToString('o')
            target_provider = $currentProvider
            codex_home = $CodexHome
            backup_root = $backupRoot
            batch_directory = $batchDirectory
            items = @($selected | ForEach-Object {
                [ordered]@{
                    session_id = [string]$_.id
                    advanced = [bool]$_.advanced_repairable
                }
            })
        }
        $planPath = Join-Path $batchDirectory 'batch-plan.json'
        [IO.File]::WriteAllText(
            $planPath,
            ($batchPlan | ConvertTo-Json -Depth 8),
            [Text.UTF8Encoding]::new($false)
        )

        $processInfo = [Diagnostics.ProcessStartInfo]::new()
        $processInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        $processInfo.WorkingDirectory = $projectRoot
        $processInfo.ArgumentList.Add('-NoLogo')
        $processInfo.ArgumentList.Add('-NoProfile')
        $processInfo.ArgumentList.Add('-File')
        $processInfo.ArgumentList.Add($batchRepairScript)
        $processInfo.ArgumentList.Add('-PlanPath')
        $processInfo.ArgumentList.Add($planPath)

        $script:repairProcess = [Diagnostics.Process]::Start($processInfo)
        $script:repairBatchDirectory = $batchDirectory
        $script:progressLineCount = 0
        $repairButton.Enabled = $false
        $scanButton.Enabled = $false
        $restoreButton.Enabled = $false
        $advancedCheck.Enabled = $false
        $statusLabel.Text = "后台修复中：0 / $($selected.Count)"
        Add-LogLine "后台修复已启动；窗口仍可移动和重绘。"
        $repairTimer.Start()
    }
    catch {
        $repairButton.Enabled = $true
        $scanButton.Enabled = $true
        $restoreButton.Enabled = $true
        $advancedCheck.Enabled = $true
        [Windows.Forms.MessageBox]::Show(
            $_.Exception.Message, '无法启动后台修复', 'OK', 'Error'
        ) | Out-Null
        Add-LogLine "无法启动后台修复：$($_.Exception.Message)"
    }
})

$restoreButton.Add_Click({
    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.Title = '选择要恢复的任务 manifest.json'
    $dialog.InitialDirectory = $backupRoot
    $dialog.Filter = 'Codex Repair manifest (manifest.json)|manifest.json'
    $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog() -ne 'OK') {
        $dialog.Dispose()
        return
    }

    try {
        $restoreManifest = Get-Content -LiteralPath $dialog.FileName -Raw |
            ConvertFrom-Json -Depth 20
        $restoreSessionId = [string]$restoreManifest.session_id
        $restoreTarget = [string]$restoreManifest.target_provider
        $answer = [Windows.Forms.MessageBox]::Show(
            "将恢复任务：$restoreSessionId`r`n" +
            "撤销同步到 provider '$restoreTarget' 的改动。`r`n" +
            "恢复前还会再备份一次当前状态，且不会整库覆盖。`r`n`r`n" +
            "请先关闭该 Codex 任务。是否继续？",
            '确认恢复备份', 'YesNo', 'Warning'
        )
        if ($answer -ne 'Yes') {
            return
        }

        $restoreButton.Enabled = $false
        $form.UseWaitCursor = $true
        $messages = & $restoreScript -ManifestPath $dialog.FileName `
            -BackupRoot $backupRoot -Confirm:$false 2>&1
        Add-LogLine "已恢复 $restoreSessionId"
        foreach ($message in $messages) {
            Add-LogLine "  $message"
        }
        [Windows.Forms.MessageBox]::Show(
            "恢复完成：$restoreSessionId`r`n请重新打开该 Codex 任务。",
            '恢复完成', 'OK', 'Information'
        ) | Out-Null
        $scanButton.PerformClick()
    }
    catch {
        Add-LogLine "恢复失败：$($_.Exception.Message)"
        [Windows.Forms.MessageBox]::Show(
            $_.Exception.Message, '恢复失败', 'OK', 'Error'
        ) | Out-Null
    }
    finally {
        $restoreButton.Enabled = $true
        $form.UseWaitCursor = $false
        $dialog.Dispose()
    }
})

$form.Add_Shown({ $scanButton.PerformClick() })
[Windows.Forms.Application]::Run($form)
