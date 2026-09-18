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
            }

            var engine = new RepairEngine(codexHome, backups);
            var scan = engine.Scan(DateTime.Today.AddDays(-1), DateTime.Today.AddDays(1), false);
            Assert(scan.Count == 1 && scan[0].AdvancedRepairable("openai"), "Fixture was not classified as advanced.");
            var repaired = engine.RepairBatch([new RepairSelection(scan[0], true)], "openai");
            Assert(repaired.Outcomes.Count == 1 && repaired.Outcomes[0].Success, "Advanced repair failed.");
            Assert(ReadHeaderProvider(rollout) == "openai", "Header provider was not repaired.");
            Assert(ReadRuntimeProvider(rollout) == "openai", "Runtime provider was not repaired.");
            Assert(ReadDatabaseProvider(database, id) == "openai", "Database provider was not repaired.");

            var manifest = Directory.EnumerateFiles(repaired.BatchDirectory, "manifest.json", SearchOption.AllDirectories).Single();
            File.AppendAllText(rollout, JsonSerializer.Serialize(new { type = "event_msg", payload = new { type = "after_repair" } }) + "\n",
                new UTF8Encoding(false));
            engine.Restore(manifest);
            Assert(ReadHeaderProvider(rollout) == "custom", "Header provider was not restored.");
            Assert(ReadRuntimeProvider(rollout) == "custom", "Runtime provider was not restored.");
            Assert(ReadDatabaseProvider(database, id) == "custom", "Database provider was not restored.");
            Assert(File.ReadAllText(rollout).Contains("after_repair", StringComparison.Ordinal), "Restore discarded appended content.");
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
}
