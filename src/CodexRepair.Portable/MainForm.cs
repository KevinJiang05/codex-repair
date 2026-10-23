using System.Diagnostics;

namespace CodexRepair;

internal sealed class MainForm : Form
{
    private readonly RepairEngine _engine;
    private readonly Label _providerLabel = new() { AutoSize = true };
    private readonly CheckBox _allDates = new() { Text = "全部日期", AutoSize = true };
    private readonly DateTimePicker _from = new() { Format = DateTimePickerFormat.Short, Width = 120 };
    private readonly DateTimePicker _to = new() { Format = DateTimePickerFormat.Short, Width = 120 };
    private readonly CheckBox _onlyProblems = new() { Text = "仅显示需要修复", Checked = true, AutoSize = true };
    private readonly Button _scan = new() { Text = "扫描", Width = 90, Height = 30 };
    private readonly DataGridView _grid = new();
    private readonly Button _select = new() { Text = "勾选可修复", Width = 120, Height = 32 };
    private readonly Button _clear = new() { Text = "清除勾选", Width = 100, Height = 32 };
    private readonly Button _repair = new() { Text = "修复勾选项", Width = 120, Height = 32 };
    private readonly CheckBox _advanced = new() { Text = "启用黄色高级修复", AutoSize = true };
    private readonly Button _restore = new() { Text = "恢复备份", Width = 105, Height = 32 };
    private readonly Label _status = new() { AutoSize = true };
    private readonly TextBox _log = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical };
    private List<ScanItem> _items = [];
    private string _scannedProvider = "";
    private bool _busy;

    public MainForm(bool demo = false)
    {
        Text = "Codex Repair 便携版";
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(1050, 650);
        Size = new Size(1280, 780);
        Font = new Font("Microsoft YaHei UI", 9F);

        var codexHome = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
        var portableRoot = Environment.GetEnvironmentVariable("CODEX_REPAIR_ROOT");
        if (string.IsNullOrWhiteSpace(portableRoot))
        {
            portableRoot = AppContext.BaseDirectory;
        }
        var backupRoot = Path.Combine(portableRoot, "backups");
        _engine = new RepairEngine(codexHome, backupRoot);
        _from.Value = DateTime.Today.AddDays(-6);
        _to.Value = DateTime.Today;

        BuildLayout();
        ConfigureGrid();
        if (!demo) WireEvents();
    }

    internal static void SaveDemoScreenshot(string path)
    {
        using var form = new MainForm(demo: true);
        form.Text = "Codex Repair · Demo / 合成数据";
        form._scannedProvider = "openai";
        form._providerLabel.Text = "目标 provider：openai";
        form._from.Value = new DateTime(2026, 10, 17);
        form._to.Value = new DateTime(2026, 10, 23);
        form._onlyProblems.Checked = false;
        var created = new DateTimeOffset(2026, 10, 23, 10, 30, 0, TimeSpan.FromHours(8));
        form._items =
        [
            new("11111111-1111-4111-8111-111111111111", created, "custom", "custom", "openai", "ok", false, "Demo: ordinary provider mismatch", "", ""),
            new("22222222-2222-4222-8222-222222222222", created.AddMinutes(-10), "custom", "custom", "custom", "ok", false, "Demo: latest runtime setting conflict", "", ""),
            new("33333333-3333-4333-8333-333333333333", created.AddMinutes(-20), "openai", "openai", "openai", "ok", true, "Demo: consistent archived thread", "", ""),
            new("44444444-4444-4444-8444-444444444444", created.AddMinutes(-30), "custom", "<missing>", "<none>", "file missing", false, "Demo: missing rollout, repair blocked", "", "")
        ];
        form.ShowItems();
        form._log.Text = "DEMO / 合成数据\r\nRed: standard repair · Yellow: runtime conflict or blocked · White: consistent\r\nThis screenshot does not read or modify a real Codex profile.";
        form.ShowInTaskbar = false;
        form.StartPosition = FormStartPosition.Manual;
        form.Location = new Point(-32000, -32000);
        form.Show();
        form.PerformLayout();
        Application.DoEvents();
        form._grid.ClearSelection();
        using var bitmap = new Bitmap(form.Width, form.Height);
        form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size));
        bitmap.Save(Path.GetFullPath(path), System.Drawing.Imaging.ImageFormat.Png);
        form.Hide();
    }

    private void BuildLayout()
    {
        _log.Dock = DockStyle.Fill;
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(12),
            RowCount = 4,
            ColumnCount = 1
        };
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 115));

        var top = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, AutoScroll = true };
        top.Controls.Add(_providerLabel);
        top.Controls.Add(Spacer(20));
        top.Controls.Add(_allDates);
        top.Controls.Add(new Label { Text = "开始：", AutoSize = true, Padding = new Padding(10, 7, 0, 0) });
        top.Controls.Add(_from);
        top.Controls.Add(new Label { Text = "结束：", AutoSize = true, Padding = new Padding(10, 7, 0, 0) });
        top.Controls.Add(_to);
        top.Controls.Add(Spacer(10));
        top.Controls.Add(_onlyProblems);
        top.Controls.Add(Spacer(20));
        top.Controls.Add(_scan);

        var actions = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, AutoScroll = true };
        actions.Controls.Add(_select);
        actions.Controls.Add(_clear);
        actions.Controls.Add(_repair);
        actions.Controls.Add(Spacer(10));
        actions.Controls.Add(_advanced);
        actions.Controls.Add(Spacer(10));
        actions.Controls.Add(_restore);
        actions.Controls.Add(Spacer(15));
        actions.Controls.Add(_status);

        root.Controls.Add(top, 0, 0);
        root.Controls.Add(_grid, 0, 1);
        root.Controls.Add(actions, 0, 2);
        root.Controls.Add(_log, 0, 3);
        Controls.Add(root);
    }

    private static Control Spacer(int width) => new Label { Width = width, Height = 1 };

    private void ConfigureGrid()
    {
        _grid.Dock = DockStyle.Fill;
        _grid.AllowUserToAddRows = false;
        _grid.AllowUserToDeleteRows = false;
        _grid.AllowUserToResizeRows = false;
        _grid.RowHeadersVisible = false;
        _grid.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
        _grid.MultiSelect = true;
        _grid.AutoGenerateColumns = false;
        _grid.Columns.Add(new DataGridViewCheckBoxColumn { Name = "Selected", HeaderText = "", Width = 35 });
        _grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "Id", HeaderText = "任务 ID", Width = 275, ReadOnly = true });
        _grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "Created", HeaderText = "创建时间", Width = 130, ReadOnly = true });
        _grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "Db", HeaderText = "数据库", Width = 80, ReadOnly = true });
        _grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "Jsonl", HeaderText = "JSONL", Width = 80, ReadOnly = true });
        _grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "Runtime", HeaderText = "运行时", Width = 80, ReadOnly = true });
        _grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "State", HeaderText = "状态", Width = 110, ReadOnly = true });
        _grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "Archived", HeaderText = "归档", Width = 55, ReadOnly = true });
        _grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "Title", HeaderText = "标题", AutoSizeMode = DataGridViewAutoSizeColumnMode.Fill, ReadOnly = true });
    }

    private void WireEvents()
    {
        _allDates.CheckedChanged += (_, _) =>
        {
            _from.Enabled = !_allDates.Checked;
            _to.Enabled = !_allDates.Checked;
        };
        _onlyProblems.CheckedChanged += (_, _) => ShowItems();
        _scan.Click += async (_, _) => await ScanAsync();
        _select.Click += (_, _) =>
        {
            foreach (DataGridViewRow row in _grid.Rows)
            {
                var item = (ScanItem)row.Tag!;
                row.Cells["Selected"].Value = item.StandardRepairable(_scannedProvider) ||
                                               _advanced.Checked && item.AdvancedRepairable(_scannedProvider);
            }
        };
        _clear.Click += (_, _) =>
        {
            foreach (DataGridViewRow row in _grid.Rows) row.Cells["Selected"].Value = false;
        };
        _repair.Click += async (_, _) => await RepairAsync();
        _restore.Click += async (_, _) => await RestoreAsync();
        Shown += async (_, _) => await ScanAsync();
    }

    private async Task ScanAsync()
    {
        if (_busy) return;
        if (!_allDates.Checked && _to.Value.Date < _from.Value.Date)
        {
            MessageBox.Show(this, "结束日期不能早于开始日期。", "日期无效", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        SetBusy(true, "正在扫描…");
        try
        {
            _scannedProvider = _engine.GetCurrentProvider();
            _providerLabel.Text = $"目标 provider：{_scannedProvider}";
            var from = _from.Value.Date;
            var to = _to.Value.Date;
            var all = _allDates.Checked;
            _items = await Task.Run(() => _engine.Scan(from, to, all));
            ShowItems();
            Log("扫描完成；未写入任何文件。");
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "扫描失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Log("扫描失败：" + exception.Message);
        }
        finally
        {
            SetBusy(false, null);
        }
    }

    private void ShowItems()
    {
        _grid.Rows.Clear();
        var visible = _onlyProblems.Checked
            ? _items.Where(item => item.NeedsRepair(_scannedProvider))
            : _items;
        foreach (var item in visible)
        {
            var state = item.FileState != "ok" ? item.FileState :
                item.StandardRepairable(_scannedProvider) ? "可自动修复" :
                item.AdvancedRepairable(_scannedProvider) ? "高级可修复" : "正常";
            var index = _grid.Rows.Add(false, item.Id, item.Created.LocalDateTime.ToString("yyyy-MM-dd HH:mm"),
                item.DatabaseProvider, item.FileProvider, item.RuntimeProvider, state,
                item.Archived ? "是" : "否", item.Title);
            var row = _grid.Rows[index];
            row.Tag = item;
            if (item.StandardRepairable(_scannedProvider)) row.DefaultCellStyle.BackColor = Color.MistyRose;
            else if (item.NeedsRepair(_scannedProvider)) row.DefaultCellStyle.BackColor = Color.LightYellow;
        }
        var problems = _items.Count(item => item.NeedsRepair(_scannedProvider));
        var standard = _items.Count(item => item.StandardRepairable(_scannedProvider));
        var advanced = _items.Count(item => item.AdvancedRepairable(_scannedProvider));
        _status.Text = $"扫描 {_items.Count}；普通 {standard}；高级 {advanced}；阻止 {problems - standard - advanced}；显示 {_grid.Rows.Count}";
    }

    private async Task RepairAsync()
    {
        if (_busy) return;
        _grid.EndEdit();
        var selected = new List<RepairSelection>();
        foreach (DataGridViewRow row in _grid.Rows)
        {
            if (row.Cells["Selected"].Value is not true) continue;
            var item = (ScanItem)row.Tag!;
            var isAdvanced = item.AdvancedRepairable(_scannedProvider);
            if (!item.StandardRepairable(_scannedProvider) && !(_advanced.Checked && isAdvanced))
            {
                MessageBox.Show(this, "选择中包含当前模式无法修复的任务。黄色任务需要启用高级修复。",
                    "无法继续", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            selected.Add(new RepairSelection(item, isAdvanced));
        }
        if (selected.Count == 0)
        {
            MessageBox.Show(this, "请先勾选至少一个任务。", "没有选择", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        var current = _engine.GetCurrentProvider();
        if (current != _scannedProvider)
        {
            MessageBox.Show(this, "当前 provider 已变化，请重新扫描。", "配置已变化", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        var advancedCount = selected.Count(value => value.Advanced);
        if (MessageBox.Show(this,
                $"将把 {selected.Count} 个任务同步到 '{current}'，其中高级修复 {advancedCount} 个。\r\n请先关闭对应 Codex 任务，并在处理期间保持关闭。\r\n写入前会创建备份。是否继续？",
                "确认修复", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
        if (advancedCount > 0 && MessageBox.Show(this,
                $"高级修复会改写 {advancedCount} 个任务最后一条生效的运行时 provider。\r\n更早历史记录保持不变。确定继续？",
                "再次确认高级修复", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;

        SetBusy(true, "后台修复准备中…");
        var progress = new Progress<RepairProgress>(value =>
        {
            _status.Text = $"后台修复：{value.Completed} / {value.Total}";
            Log(value.Message);
        });
        try
        {
            var result = await Task.Run(() => _engine.RepairBatch(selected, current, progress));
            var success = result.Outcomes.Count(value => value.Success);
            var failed = result.Outcomes.Count - success;
            MessageBox.Show(this,
                $"处理完成：成功 {success}，失败 {failed}。\r\n备份与报告：{result.BatchDirectory}\r\n请重新扫描并打开相关任务验证。",
                "处理完成", MessageBoxButtons.OK, failed > 0 ? MessageBoxIcon.Warning : MessageBoxIcon.Information);
            _status.Text = $"处理完成：成功 {success}，失败 {failed}；请重新扫描";
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "修复失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Log("修复失败：" + exception.Message);
        }
        finally
        {
            SetBusy(false, null);
        }
    }

    private async Task RestoreAsync()
    {
        if (_busy) return;
        using var dialog = new OpenFileDialog
        {
            Title = "选择任务 manifest.json",
            InitialDirectory = _engine.BackupRoot,
            Filter = "Codex Repair manifest (manifest.json)|manifest.json",
            CheckFileExists = true
        };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        if (MessageBox.Show(this,
                "将按 manifest 定点恢复 provider 字段。恢复前会再次备份当前状态，不会整库覆盖。\r\n请先关闭对应 Codex 任务。是否继续？",
                "确认恢复", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
        SetBusy(true, "正在恢复…");
        try
        {
            var recovery = await Task.Run(() => _engine.Restore(dialog.FileName));
            MessageBox.Show(this, $"恢复完成。\r\n恢复前备份：{recovery}\r\n请重新打开任务。",
                "恢复完成", MessageBoxButtons.OK, MessageBoxIcon.Information);
            Log("恢复完成：" + recovery);
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "恢复失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Log("恢复失败：" + exception.Message);
        }
        finally
        {
            SetBusy(false, null);
        }
    }

    private void SetBusy(bool busy, string? status)
    {
        _busy = busy;
        _scan.Enabled = !busy;
        _repair.Enabled = !busy;
        _restore.Enabled = !busy;
        _advanced.Enabled = !busy;
        _select.Enabled = !busy;
        if (status is not null) _status.Text = status;
    }

    private void Log(string text)
    {
        _log.AppendText($"{DateTime.Now:HH:mm:ss}  {text}\r\n");
    }
}
