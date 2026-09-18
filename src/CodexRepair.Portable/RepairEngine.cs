using Microsoft.Data.Sqlite;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace CodexRepair;

internal sealed class RepairEngine
{
    private static readonly Regex ProviderValue = new("^[A-Za-z0-9_-]+$", RegexOptions.Compiled);
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    public string CodexHome { get; }
    public string BackupRoot { get; }

    public RepairEngine(string codexHome, string backupRoot)
    {
        CodexHome = Path.GetFullPath(codexHome);
        BackupRoot = Path.GetFullPath(backupRoot);
    }

    public string GetCurrentProvider()
    {
        var configPath = Path.Combine(CodexHome, "config.toml");
        if (!File.Exists(configPath)) throw new InvalidOperationException($"找不到 Codex 配置：{configPath}");
        var text = File.ReadAllText(configPath, Encoding.UTF8);
        var match = Regex.Match(text, "(?m)^\\s*model_provider\\s*=\\s*\"([A-Za-z0-9_-]+)\"\\s*$");
        var provider = match.Success ? match.Groups[1].Value : "openai";
        ValidateProvider(provider);
        if (provider is not ("openai" or "ollama" or "lmstudio" or "amazon-bedrock"))
        {
            var section = "(?m)^\\s*\\[model_providers\\." + Regex.Escape(provider) + "\\]\\s*$";
            if (!Regex.IsMatch(text, section))
                throw new InvalidOperationException($"config.toml 未定义 provider '{provider}'。");
        }
        return provider;
    }

    public List<ScanItem> Scan(DateTime from, DateTime to, bool allDates, CancellationToken cancellationToken = default)
    {
        var target = GetCurrentProvider();
        var start = allDates ? 0L : new DateTimeOffset(from.Date).ToUnixTimeSeconds();
        var end = allDates ? long.MaxValue : new DateTimeOffset(to.Date.AddDays(1)).ToUnixTimeSeconds();
        var results = new List<ScanItem>();

        foreach (var database in Directory.EnumerateFiles(CodexHome, "state_*.sqlite", SearchOption.TopDirectoryOnly)
                     .Where(path => Regex.IsMatch(Path.GetFileName(path), "^state_[0-9]+\\.sqlite$")))
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var connection = Open(database, readOnly: true);
            using var command = connection.CreateCommand();
            command.CommandText = "select id, rollout_path, created_at, model_provider, title, archived " +
                                  "from threads where created_at >= $start and created_at < $end order by created_at desc";
            command.Parameters.AddWithValue("$start", start);
            command.Parameters.AddWithValue("$end", end);
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                cancellationToken.ThrowIfCancellationRequested();
                var id = reader.GetString(0);
                var rollout = reader.IsDBNull(1) ? "" : reader.GetString(1);
                var created = DateTimeOffset.FromUnixTimeSeconds(reader.GetInt64(2));
                var dbProvider = reader.IsDBNull(3) ? "<missing>" : reader.GetString(3);
                var title = reader.IsDBNull(4) ? "" : reader.GetString(4);
                var archived = !reader.IsDBNull(5) && reader.GetBoolean(5);
                var inspection = InspectSession(rollout, id, includeLatestLine: false);
                results.Add(new ScanItem(
                    id, created, dbProvider, inspection.FileProvider ?? "<missing>",
                    inspection.RuntimeProvider ?? "<none>", inspection.FileState,
                    archived, title, database, rollout));
            }
        }
        return results.OrderByDescending(item => item.Created).ToList();
    }

    public (string BatchDirectory, List<RepairOutcome> Outcomes) RepairBatch(
        IReadOnlyList<RepairSelection> selections,
        string targetProvider,
        IProgress<RepairProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ValidateProvider(targetProvider);
        Directory.CreateDirectory(BackupRoot);
        var stamp = DateTime.Now.ToString("yyyyMMdd-HHmmssfff");
        var batchDirectory = Path.Combine(BackupRoot, $"{stamp}-batch-{selections.Count}");
        Directory.CreateDirectory(batchDirectory);
        var outcomes = new List<RepairOutcome>();
        var databaseBackups = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        for (var index = 0; index < selections.Count; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var selection = selections[index];
            progress?.Report(new RepairProgress(index, selections.Count, $"开始 {selection.Item.Id}"));
            try
            {
                RepairOne(selection, targetProvider, batchDirectory, databaseBackups);
                outcomes.Add(new RepairOutcome(selection.Item.Id, true, selection.Advanced, null));
                progress?.Report(new RepairProgress(index + 1, selections.Count, $"完成 {selection.Item.Id}"));
            }
            catch (Exception exception)
            {
                outcomes.Add(new RepairOutcome(selection.Item.Id, false, selection.Advanced, exception.Message));
                progress?.Report(new RepairProgress(index + 1, selections.Count, $"失败 {selection.Item.Id}：{exception.Message}"));
            }
            WriteBatchReport(batchDirectory, targetProvider, selections.Count, outcomes);
        }
        return (batchDirectory, outcomes);
    }

    public string Restore(string manifestPath)
    {
        var normalizedManifest = Path.GetFullPath(manifestPath);
        EnsureInside(normalizedManifest, BackupRoot, "只能恢复当前便携包 backups 目录中的 manifest.json。");
        if (!string.Equals(Path.GetFileName(normalizedManifest), "manifest.json", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("请选择任务目录中的 manifest.json。");
        var manifest = JsonSerializer.Deserialize<RepairManifest>(File.ReadAllText(normalizedManifest), JsonOptions)
                       ?? throw new InvalidOperationException("无法读取备份清单。");
        ValidateProvider(manifest.TargetProvider);
        ValidateProvider(manifest.SessionProviderBefore);
        ValidateProvider(manifest.DatabaseProviderBefore);
        if (!File.Exists(manifest.StateDatabase)) throw new FileNotFoundException("当前状态数据库不存在。", manifest.StateDatabase);

        var row = GetDatabaseRow(manifest.StateDatabase, manifest.SessionId)
                  ?? throw new InvalidOperationException("状态数据库中已经找不到该任务。");
        var sessionPath = Path.GetFullPath(row.RolloutPath);
        if (!File.Exists(sessionPath)) throw new FileNotFoundException("当前任务 JSONL 不存在。", sessionPath);
        var inspection = InspectSession(sessionPath, manifest.SessionId, includeLatestLine: true);
        if (inspection.FileState != "ok") throw new InvalidOperationException("当前任务 JSONL 无法安全恢复。");

        var bytes = ReadAllBytesShared(sessionPath);
        var newBytes = bytes;
        var sessionChanged = false;
        if (manifest.SessionProviderBefore != manifest.TargetProvider)
        {
            RequireBackup(manifest.SessionBackup, "原 JSONL 备份缺失，恢复已拒绝。");
            if (inspection.FileProvider != manifest.TargetProvider)
                throw new InvalidOperationException("任务头 provider 在修复后又发生了变化，恢复已拒绝。");
            var first = GetLine(newBytes, 1);
            var restored = ReplaceProviderMarker(first, "model_provider", manifest.TargetProvider, manifest.SessionProviderBefore);
            newBytes = ReplaceLine(newBytes, 1, restored);
            sessionChanged = true;
        }

        if (manifest.RuntimeRewrites.Count > 0)
        {
            RequireBackup(manifest.SessionBackup, "原 JSONL 备份缺失，运行时恢复已拒绝。");
            var lastRewrite = manifest.RuntimeRewrites[^1];
            if (inspection.RuntimeLineNumber != lastRewrite.LineNumber)
                throw new InvalidOperationException("修复后出现了新的运行时设置，恢复已拒绝。");
            foreach (var rewrite in manifest.RuntimeRewrites)
            {
                ValidateProvider(rewrite.Before);
                ValidateProvider(rewrite.After);
                var line = GetLine(newBytes, rewrite.LineNumber);
                using var document = JsonDocument.Parse(line);
                var current = GetRuntimeProvider(document.RootElement);
                if (current != rewrite.After)
                    throw new InvalidOperationException($"第 {rewrite.LineNumber} 行运行时 provider 已变化，恢复已拒绝。");
                var restored = ReplaceProviderMarker(line, "model_provider_id", rewrite.After, rewrite.Before);
                newBytes = ReplaceLine(newBytes, rewrite.LineNumber, restored);
            }
            sessionChanged = true;
        }

        var databaseChanged = manifest.DatabaseProviderBefore != manifest.TargetProvider;
        if (databaseChanged)
        {
            RequireBackup(manifest.DatabaseBackup, "原数据库备份缺失，恢复已拒绝。");
            if (row.Provider != manifest.TargetProvider)
                throw new InvalidOperationException("数据库 provider 在修复后又发生了变化，恢复已拒绝。");
        }
        if (!sessionChanged && !databaseChanged) return "无需恢复。";

        Directory.CreateDirectory(BackupRoot);
        var recoveryDirectory = Path.Combine(BackupRoot, $"{DateTime.Now:yyyyMMdd-HHmmssfff}-pre-restore-{manifest.SessionId}");
        Directory.CreateDirectory(recoveryDirectory);
        var originalTime = File.GetLastWriteTimeUtc(sessionPath);
        var currentSessionBackup = sessionChanged ? Path.Combine(recoveryDirectory, Path.GetFileName(sessionPath) + ".bak") : null;
        var currentDatabaseBackup = databaseChanged ? Path.Combine(recoveryDirectory, Path.GetFileName(manifest.StateDatabase) + ".bak") : null;
        var replaced = false;
        try
        {
            if (sessionChanged)
            {
                File.Copy(sessionPath, currentSessionBackup!, overwrite: false);
                AtomicWrite(sessionPath, newBytes);
                File.SetLastWriteTimeUtc(sessionPath, originalTime);
                replaced = true;
            }
            if (databaseChanged)
            {
                BackupDatabase(manifest.StateDatabase, currentDatabaseBackup!);
                UpdateDatabaseProvider(manifest.StateDatabase, manifest.SessionId, manifest.TargetProvider,
                    manifest.DatabaseProviderBefore, sessionPath);
            }
        }
        catch
        {
            if (replaced && currentSessionBackup is not null)
            {
                File.Copy(currentSessionBackup, sessionPath, overwrite: true);
                File.SetLastWriteTimeUtc(sessionPath, originalTime);
            }
            throw;
        }

        File.WriteAllText(Path.Combine(recoveryDirectory, "restore-report.json"),
            JsonSerializer.Serialize(new
            {
                version = 1,
                operation = "pre_restore_backup",
                created_at = DateTimeOffset.Now.ToString("O"),
                source_manifest = normalizedManifest,
                session_id = manifest.SessionId,
                session_file = sessionPath,
                session_backup = currentSessionBackup,
                state_database = manifest.StateDatabase,
                database_backup = currentDatabaseBackup
            }, JsonOptions), new UTF8Encoding(false));
        return recoveryDirectory;
    }

    private void RepairOne(RepairSelection selection, string target, string batchDirectory,
        Dictionary<string, string> databaseBackups)
    {
        var item = selection.Item;
        var row = GetDatabaseRow(item.DatabasePath, item.Id)
                  ?? throw new InvalidOperationException("状态数据库中已找不到该任务。");
        if (!SamePath(row.RolloutPath, item.RolloutPath))
            throw new InvalidOperationException("任务 JSONL 路径在扫描后发生变化，请重新扫描。");
        var inspection = InspectSession(item.RolloutPath, item.Id, includeLatestLine: true);
        if (inspection.FileState != "ok") throw new InvalidOperationException("任务 JSONL 无法安全读取。");
        var runtimeNeedsChange = inspection.RuntimeProvider is not null && inspection.RuntimeProvider != target;
        if (runtimeNeedsChange && !selection.Advanced)
            throw new InvalidOperationException("检测到运行时 provider 冲突，需要高级修复。");
        var headerNeedsChange = inspection.FileProvider != target;
        var databaseNeedsChange = row.Provider != target;
        if (!headerNeedsChange && !runtimeNeedsChange && !databaseNeedsChange) return;

        var bytes = ReadAllBytesShared(item.RolloutPath);
        var newBytes = bytes;
        if (headerNeedsChange)
        {
            var first = GetLine(newBytes, 1);
            newBytes = ReplaceLine(newBytes, 1,
                ReplaceProviderMarker(first, "model_provider", inspection.FileProvider!, target));
        }
        var rewrites = new List<RuntimeRewrite>();
        if (runtimeNeedsChange)
        {
            if (inspection.RuntimeLineNumber is null || inspection.RuntimeLine is null)
                throw new InvalidOperationException("找不到最后一条运行时 provider 记录。");
            var replacedLine = ReplaceProviderMarker(inspection.RuntimeLine, "model_provider_id",
                inspection.RuntimeProvider!, target);
            newBytes = ReplaceLine(newBytes, inspection.RuntimeLineNumber.Value, replacedLine);
            rewrites.Add(new RuntimeRewrite(inspection.RuntimeLineNumber.Value, inspection.RuntimeProvider!, target));
        }

        var sessionDirectory = Path.Combine(batchDirectory, "sessions", item.Id);
        Directory.CreateDirectory(sessionDirectory);
        var sessionBackup = headerNeedsChange || runtimeNeedsChange
            ? Path.Combine(sessionDirectory, Path.GetFileName(item.RolloutPath) + ".bak")
            : null;
        string? databaseBackup = null;
        if (databaseNeedsChange)
        {
            if (!databaseBackups.TryGetValue(item.DatabasePath, out databaseBackup))
            {
                databaseBackup = Path.Combine(batchDirectory, Path.GetFileName(item.DatabasePath) + ".bak");
                BackupDatabase(item.DatabasePath, databaseBackup);
                databaseBackups[item.DatabasePath] = databaseBackup;
            }
        }

        var originalTime = File.GetLastWriteTimeUtc(item.RolloutPath);
        var replaced = false;
        try
        {
            if (sessionBackup is not null)
            {
                File.Copy(item.RolloutPath, sessionBackup, overwrite: false);
                AtomicWrite(item.RolloutPath, newBytes);
                File.SetLastWriteTimeUtc(item.RolloutPath, originalTime);
                replaced = true;
                var verification = InspectSession(item.RolloutPath, item.Id, includeLatestLine: false);
                if (verification.FileProvider != target || runtimeNeedsChange && verification.RuntimeProvider != target)
                    throw new InvalidOperationException("JSONL 写入后验证失败。");
            }
            if (databaseNeedsChange)
                UpdateDatabaseProvider(item.DatabasePath, item.Id, row.Provider, target, item.RolloutPath);
        }
        catch
        {
            if (replaced && sessionBackup is not null)
            {
                File.Copy(sessionBackup, item.RolloutPath, overwrite: true);
                File.SetLastWriteTimeUtc(item.RolloutPath, originalTime);
            }
            throw;
        }

        var manifest = new RepairManifest
        {
            SessionId = item.Id,
            TargetProvider = target,
            SessionFile = item.RolloutPath,
            SessionProviderBefore = inspection.FileProvider!,
            SessionBackup = sessionBackup,
            StateDatabase = item.DatabasePath,
            DatabaseProviderBefore = row.Provider,
            DatabaseBackup = databaseBackup,
            RuntimeLatestProvider = inspection.RuntimeProvider,
            RuntimeRewrites = rewrites,
            BatchBackupDirectory = batchDirectory
        };
        File.WriteAllText(Path.Combine(sessionDirectory, "manifest.json"),
            JsonSerializer.Serialize(manifest, JsonOptions), new UTF8Encoding(false));
    }

    private static void WriteBatchReport(string directory, string target, int selected, List<RepairOutcome> outcomes)
    {
        var report = new
        {
            version = 3,
            status = outcomes.Count == selected ? "completed" : "running",
            updated_at = DateTimeOffset.Now.ToString("O"),
            target_provider = target,
            selected_count = selected,
            completed_count = outcomes.Count,
            success_count = outcomes.Count(result => result.Success),
            failed_count = outcomes.Count(result => !result.Success),
            results = outcomes.Select(result => new
            {
                session_id = result.SessionId,
                status = result.Success ? "success" : "failed",
                repair_mode = result.Advanced ? "advanced" : "standard",
                error = result.Error
            })
        };
        var path = Path.Combine(directory, "batch-report.json");
        var temp = path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(report, JsonOptions), new UTF8Encoding(false));
        File.Move(temp, path, overwrite: true);
    }

    private static SessionInspection InspectSession(string path, string expectedId, bool includeLatestLine)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            return new SessionInspection("file missing", null, null, null, null);
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete, 64 * 1024, FileOptions.SequentialScan);
            using var reader = new StreamReader(stream, Encoding.UTF8, true, 64 * 1024);
            var first = reader.ReadLine() ?? throw new InvalidDataException("JSONL 为空。");
            using var metadata = JsonDocument.Parse(first);
            var root = metadata.RootElement;
            if (root.GetProperty("type").GetString() != "session_meta")
                return new SessionInspection("invalid metadata", null, null, null, null);
            var payload = root.GetProperty("payload");
            if (payload.GetProperty("id").GetString() != expectedId)
                return new SessionInspection("id mismatch", null, null, null, null);
            var fileProvider = payload.TryGetProperty("model_provider", out var providerElement)
                ? providerElement.GetString() : null;
            string? runtimeProvider = null;
            string? runtimeLine = null;
            int? runtimeLineNumber = null;
            var lineNumber = 1;
            string? line;
            while ((line = reader.ReadLine()) is not null)
            {
                lineNumber++;
                if (!line.Contains("thread_settings_applied", StringComparison.Ordinal)) continue;
                using var document = JsonDocument.Parse(line);
                var candidate = GetRuntimeProvider(document.RootElement);
                if (candidate is null) continue;
                runtimeProvider = candidate;
                runtimeLineNumber = lineNumber;
                if (includeLatestLine) runtimeLine = line;
            }
            return new SessionInspection(fileProvider is null ? "provider missing" : "ok",
                fileProvider, runtimeProvider, runtimeLineNumber, runtimeLine);
        }
        catch
        {
            return new SessionInspection("file unreadable", null, null, null, null);
        }
    }

    private static string? GetRuntimeProvider(JsonElement root)
    {
        if (!root.TryGetProperty("payload", out var payload) ||
            !payload.TryGetProperty("type", out var type) || type.GetString() != "thread_settings_applied" ||
            !payload.TryGetProperty("thread_settings", out var settings) ||
            !settings.TryGetProperty("model_provider_id", out var provider)) return null;
        return provider.GetString();
    }

    private static SqliteConnection Open(string path, bool readOnly)
    {
        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = readOnly ? SqliteOpenMode.ReadOnly : SqliteOpenMode.ReadWrite,
            Cache = SqliteCacheMode.Private,
            DefaultTimeout = 10,
            Pooling = false
        };
        var connection = new SqliteConnection(builder.ToString());
        connection.Open();
        return connection;
    }

    private static (string Provider, string RolloutPath)? GetDatabaseRow(string database, string id)
    {
        using var connection = Open(database, readOnly: true);
        using var command = connection.CreateCommand();
        command.CommandText = "select model_provider, rollout_path from threads where id = $id";
        command.Parameters.AddWithValue("$id", id);
        using var reader = command.ExecuteReader();
        if (!reader.Read()) return null;
        return (reader.GetString(0), reader.GetString(1));
    }

    private static void UpdateDatabaseProvider(string database, string id, string expected,
        string target, string rolloutPath)
    {
        using var connection = Open(database, readOnly: false);
        using var transaction = connection.BeginTransaction();
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "update threads set model_provider = $target " +
                              "where id = $id and model_provider = $expected and rollout_path = $path";
        command.Parameters.AddWithValue("$target", target);
        command.Parameters.AddWithValue("$id", id);
        command.Parameters.AddWithValue("$expected", expected);
        command.Parameters.AddWithValue("$path", rolloutPath);
        if (command.ExecuteNonQuery() != 1)
            throw new InvalidOperationException("数据库状态在扫描后发生变化，未执行写入。");
        transaction.Commit();
    }

    private static void BackupDatabase(string sourcePath, string destinationPath)
    {
        if (File.Exists(destinationPath)) throw new IOException($"数据库备份已存在：{destinationPath}");
        using var source = Open(sourcePath, readOnly: true);
        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = destinationPath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false
        };
        using var destination = new SqliteConnection(builder.ToString());
        destination.Open();
        source.BackupDatabase(destination);
        using var check = destination.CreateCommand();
        check.CommandText = "pragma quick_check";
        if (!string.Equals(check.ExecuteScalar()?.ToString(), "ok", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("数据库备份 quick_check 失败。");
    }

    private static byte[] ReadAllBytesShared(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete, 1024 * 1024, FileOptions.SequentialScan);
        using var memory = stream.Length <= int.MaxValue ? new MemoryStream((int)stream.Length) : new MemoryStream();
        stream.CopyTo(memory);
        return memory.ToArray();
    }

    private static string GetLine(byte[] bytes, int lineNumber)
    {
        var (start, end, _, _) = LocateLine(bytes, lineNumber);
        return Encoding.UTF8.GetString(bytes, start, end - start);
    }

    private static byte[] ReplaceLine(byte[] bytes, int lineNumber, string newLine)
    {
        var (start, end, tail, endingLength) = LocateLine(bytes, lineNumber);
        var replacement = Encoding.UTF8.GetBytes(newLine);
        var result = new byte[start + replacement.Length + endingLength + bytes.Length - tail];
        Buffer.BlockCopy(bytes, 0, result, 0, start);
        Buffer.BlockCopy(replacement, 0, result, start, replacement.Length);
        if (endingLength > 0) Buffer.BlockCopy(bytes, end, result, start + replacement.Length, endingLength);
        Buffer.BlockCopy(bytes, tail, result, start + replacement.Length + endingLength, bytes.Length - tail);
        return result;
    }

    private static (int Start, int End, int Tail, int EndingLength) LocateLine(byte[] bytes, int lineNumber)
    {
        if (lineNumber < 1) throw new ArgumentOutOfRangeException(nameof(lineNumber));
        var start = 0;
        for (var current = 1; current < lineNumber; current++)
        {
            var feed = Array.IndexOf(bytes, (byte)'\n', start);
            if (feed < 0) throw new InvalidDataException($"JSONL 不存在第 {lineNumber} 行。");
            start = feed + 1;
        }
        var lineFeed = Array.IndexOf(bytes, (byte)'\n', start);
        if (lineFeed < 0) return (start, bytes.Length, bytes.Length, 0);
        var end = lineFeed > start && bytes[lineFeed - 1] == '\r' ? lineFeed - 1 : lineFeed;
        return (start, end, lineFeed + 1, lineFeed + 1 - end);
    }

    private static string ReplaceProviderMarker(string line, string property, string before, string after)
    {
        ValidateProvider(before);
        ValidateProvider(after);
        var regex = new Regex("(\\\"" + Regex.Escape(property) + "\\\"\\s*:\\s*)\\\"" +
                              Regex.Escape(before) + "\\\"");
        if (regex.Matches(line).Count != 1)
            throw new InvalidDataException($"字段 {property} 不满足唯一替换条件。");
        return regex.Replace(line, match => match.Groups[1].Value + "\"" + after + "\"", 1);
    }

    private static void AtomicWrite(string destination, byte[] bytes)
    {
        var temp = destination + ".codex-repair-" + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllBytes(temp, bytes);
            using (var stream = new FileStream(temp, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (stream.Length != bytes.LongLength) throw new IOException("临时文件长度验证失败。");
            }
            File.Move(temp, destination, overwrite: true);
        }
        finally
        {
            if (File.Exists(temp)) File.Delete(temp);
        }
    }

    private static void ValidateProvider(string provider)
    {
        if (string.IsNullOrWhiteSpace(provider) || !ProviderValue.IsMatch(provider))
            throw new InvalidDataException($"无效 provider：{provider}");
    }

    private static void RequireBackup(string? path, string message)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path)) throw new InvalidOperationException(message);
    }

    private static void EnsureInside(string path, string root, string message)
    {
        var normalizedRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!Path.GetFullPath(path).StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException(message);
    }

    private static bool SamePath(string left, string right) =>
        string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase);

    private readonly record struct SessionInspection(
        string FileState,
        string? FileProvider,
        string? RuntimeProvider,
        int? RuntimeLineNumber,
        string? RuntimeLine);
}
