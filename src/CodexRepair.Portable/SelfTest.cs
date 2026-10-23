using Microsoft.Data.Sqlite;
using System.Text;
using System.Text.Json;

namespace CodexRepair;

internal static class SelfTest
{
    public static void Run()
    {
        var testsRoot = Path.GetFullPath(Path.Combine(Environment.CurrentDirectory, "tests"));
        Directory.CreateDirectory(testsRoot);
        var root = Path.Combine(testsRoot, ".portable-selftest-" + Guid.NewGuid().ToString("N"));
        if (!Path.GetFullPath(root).StartsWith(testsRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Self-test root escaped the tests directory.");

        try
        {
            var codexHome = Path.Combine(root, ".codex");
            var sessions = Path.Combine(codexHome, "sessions", "2026", "09", "18");
            var backups = Path.Combine(root, "backups");
            Directory.CreateDirectory(sessions);
            File.WriteAllText(Path.Combine(codexHome, "config.toml"), "model_provider = \"openai\"\n", new UTF8Encoding(false));

            const string id = "44444444-4444-4444-8444-444444444444";
            var rollout = Path.Combine(sessions, $"rollout-2026-09-18T00-00-00-{id}.jsonl");
            var lines = new[]
            {
                JsonSerializer.Serialize(new { type = "session_meta", payload = new { id, model_provider = "custom" } }),
                JsonSerializer.Serialize(new
                {
                    type = "event_msg",
                    payload = new
                    {
                        type = "thread_settings_applied",
                        thread_settings = new { model_provider_id = "custom" }
                    }
                })
            };
            File.WriteAllText(rollout, string.Join('\n', lines) + "\n", new UTF8Encoding(false));

            var database = Path.Combine(codexHome, "state_5.sqlite");
            using (var connection = new SqliteConnection($"Data Source={database};Pooling=False"))
            {
                connection.Open();
                using var command = connection.CreateCommand();
                command.CommandText = "create table threads (id text primary key, rollout_path text, created_at integer, " +
                                      "model_provider text, title text, archived integer); " +
                                      "insert into threads values ($id, $path, $created, 'custom', 'fixture', 0)";
                command.Parameters.AddWithValue("$id", id);
                command.Parameters.AddWithValue("$path", rollout);
                command.Parameters.AddWithValue("$created", DateTimeOffset.Now.ToUnixTimeSeconds());
                command.ExecuteNonQuery();
                command.CommandText = "select sqlite_version()";
                var sqliteVersion = Version.Parse((string)command.ExecuteScalar()!);
                Assert(sqliteVersion >= new Version(3, 50, 2), "Bundled SQLite predates the CVE-2025-6965 fix.");
                Console.WriteLine("SQLite: " + sqliteVersion);
            }

            var engine = new RepairEngine(codexHome, backups);
            File.WriteAllText(Path.Combine(codexHome, "config.toml"), "[profiles.demo]\nmodel_provider = \"nested-only\"\n");
            Assert(engine.GetCurrentProvider() == "openai", "Nested profile provider was treated as a root setting.");
            File.WriteAllText(Path.Combine(codexHome, "config.toml"), "model_provider = \"openai\" # fixture comment\n");
            var scan = engine.Scan(DateTime.Today.AddDays(-1), DateTime.Today.AddDays(1), false);
            Assert(scan.Count == 1 && scan[0].AdvancedRepairable("openai"), "Fixture was not classified as advanced.");
            var originalBytes = File.ReadAllBytes(rollout);
            var originalTime = File.GetLastWriteTimeUtc(rollout);
            using (var writer = new FileStream(rollout, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
            {
                var busy = engine.RepairBatch([new RepairSelection(scan[0], true)], "openai");
                Assert(!busy.Outcomes[0].Success, "Repair accepted an open writer.");
                Assert(ReadDatabaseProvider(database, id) == "custom", "Busy-file refusal changed SQLite.");
            }
            Assert(File.ReadAllBytes(rollout).SequenceEqual(originalBytes), "Busy-file refusal changed JSONL.");

            // Make manifest.json unwritable using a directory, through the real batch progress callback.
            var manifestFailure = engine.RepairBatch([new RepairSelection(scan[0], true)], "openai",
                new CallbackProgress(progress =>
                {
                    if (progress.Completed != 0) return;
                    var batch = Directory.GetDirectories(backups).OrderBy(path => path, StringComparer.Ordinal).Last();
                    Directory.CreateDirectory(Path.Combine(batch, "sessions", id, "manifest.json"));
                }));
            Assert(!manifestFailure.Outcomes[0].Success, "Unwritable manifest was ignored.");
            Assert(File.ReadAllBytes(rollout).SequenceEqual(originalBytes), "Manifest failure changed JSONL.");
            Assert(ReadDatabaseProvider(database, id) == "custom", "Manifest failure changed SQLite.");

            Execute(database, "create trigger refuse_update before update on threads begin select raise(abort, 'fixture database failure'); end");
            var databaseFailure = engine.RepairBatch([new RepairSelection(scan[0], true)], "openai");
            Assert(!databaseFailure.Outcomes[0].Success, "Database failure was ignored.");
            Assert(File.ReadAllBytes(rollout).SequenceEqual(originalBytes), "Database failure did not roll back JSONL.");
            Assert(File.GetLastWriteTimeUtc(rollout) == originalTime, "Rollback changed JSONL mtime.");
            Assert(ReadDatabaseProvider(database, id) == "custom", "Failed transaction changed SQLite.");
            Execute(database, "drop trigger refuse_update");

            var repaired = engine.RepairBatch([new RepairSelection(scan[0], true)], "openai");
            Assert(repaired.Outcomes.Count == 1 && repaired.Outcomes[0].Success, "Advanced repair failed: " + repaired.Outcomes.FirstOrDefault()?.Error);
            Assert(ReadHeaderProvider(rollout) == "openai", "Header provider was not repaired.");
            Assert(ReadRuntimeProvider(rollout) == "openai", "Runtime provider was not repaired.");
            Assert(ReadDatabaseProvider(database, id) == "openai", "Database provider was not repaired.");

            var manifest = Directory.EnumerateFiles(repaired.BatchDirectory, "manifest.json", SearchOption.AllDirectories).Single();
            File.AppendAllText(rollout, JsonSerializer.Serialize(new { type = "event_msg", payload = new { type = "after_repair" } }) + "\n",
                new UTF8Encoding(false));
            var appendedBytes = File.ReadAllBytes(rollout);
            using (var writer = new FileStream(rollout, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
            {
                AssertThrows<IOException>(() => engine.Restore(manifest), "Restore accepted an open writer.");
            }
            Assert(File.ReadAllBytes(rollout).SequenceEqual(appendedBytes), "Busy restore lost appended content.");
            engine.Restore(manifest);
            Assert(ReadHeaderProvider(rollout) == "custom", "Header provider was not restored.");
            Assert(ReadRuntimeProvider(rollout) == "custom", "Runtime provider was not restored.");
            Assert(ReadDatabaseProvider(database, id) == "custom", "Database provider was not restored.");
            Assert(File.ReadAllText(rollout).Contains("after_repair", StringComparison.Ordinal), "Restore discarded appended content.");

            Execute(database, "alter table threads rename column model_provider to unsupported_provider");
            var unknownBytes = File.ReadAllBytes(rollout);
            AssertThrows<InvalidDataException>(() => engine.Scan(DateTime.Today, DateTime.Today, true),
                "Unknown database schema was accepted.");
            var unknownRepair = engine.RepairBatch([new RepairSelection(scan[0], true)], "openai");
            Assert(!unknownRepair.Outcomes[0].Success, "Repair accepted an unknown schema.");
            Assert(File.ReadAllBytes(rollout).SequenceEqual(unknownBytes), "Unknown schema changed JSONL.");
            Console.WriteLine("PASS: writer refusal, manifest failure, DB rollback, mtime, appended content, unknown schema.");
        }
        finally
        {
            if (Directory.Exists(root) && Path.GetFullPath(root).StartsWith(testsRoot + Path.DirectorySeparatorChar,
                    StringComparison.OrdinalIgnoreCase))
                Directory.Delete(root, recursive: true);
        }
    }

    private static string ReadHeaderProvider(string path)
    {
        using var document = JsonDocument.Parse(File.ReadLines(path).First());
        return document.RootElement.GetProperty("payload").GetProperty("model_provider").GetString()!;
    }

    private static string ReadRuntimeProvider(string path)
    {
        string? provider = null;
        foreach (var line in File.ReadLines(path))
        {
            if (!line.Contains("thread_settings_applied", StringComparison.Ordinal)) continue;
            using var document = JsonDocument.Parse(line);
            provider = document.RootElement.GetProperty("payload").GetProperty("thread_settings")
                .GetProperty("model_provider_id").GetString();
        }
        return provider ?? throw new InvalidOperationException("Runtime provider missing.");
    }

    private static string ReadDatabaseProvider(string path, string id)
    {
        using var connection = new SqliteConnection($"Data Source={path};Mode=ReadOnly;Pooling=False");
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = "select model_provider from threads where id = $id";
        command.Parameters.AddWithValue("$id", id);
        return (string)command.ExecuteScalar()!;
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Execute(string database, string sql)
    {
        using var connection = new SqliteConnection($"Data Source={database};Pooling=False");
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    private static void AssertThrows<T>(Action action, string message) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException(message);
    }

    private sealed class CallbackProgress(Action<RepairProgress> callback) : IProgress<RepairProgress>
    {
        public void Report(RepairProgress value) => callback(value);
    }
}
