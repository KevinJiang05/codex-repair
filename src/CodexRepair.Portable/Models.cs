using System.Text.Json.Serialization;

namespace CodexRepair;

internal sealed record ScanItem(
    string Id,
    DateTimeOffset Created,
    string DatabaseProvider,
    string FileProvider,
    string RuntimeProvider,
    string FileState,
    bool Archived,
    string Title,
    string DatabasePath,
    string RolloutPath)
{
    public bool NeedsRepair(string target) =>
        DatabaseProvider != target || FileProvider != target ||
        RuntimeProvider is not "<none>" && RuntimeProvider != target || FileState != "ok";

    public bool StandardRepairable(string target) =>
        NeedsRepair(target) && FileState == "ok" &&
        (RuntimeProvider == "<none>" || RuntimeProvider == target);

    public bool AdvancedRepairable(string target) =>
        NeedsRepair(target) && FileState == "ok" &&
        RuntimeProvider is not "<none>" && RuntimeProvider != target;
}

internal sealed record RepairSelection(ScanItem Item, bool Advanced);

internal sealed record RuntimeRewrite(
    [property: JsonPropertyName("line_number")] int LineNumber,
    [property: JsonPropertyName("before")] string Before,
    [property: JsonPropertyName("after")] string After);

internal sealed class RepairManifest
{
    [JsonPropertyName("version")] public int Version { get; set; } = 3;
    [JsonPropertyName("created_at")] public string CreatedAt { get; set; } = DateTimeOffset.Now.ToString("O");
    [JsonPropertyName("session_id")] public string SessionId { get; set; } = "";
    [JsonPropertyName("target_provider")] public string TargetProvider { get; set; } = "";
    [JsonPropertyName("session_file")] public string SessionFile { get; set; } = "";
    [JsonPropertyName("session_provider_before")] public string SessionProviderBefore { get; set; } = "";
    [JsonPropertyName("session_backup")] public string? SessionBackup { get; set; }
    [JsonPropertyName("state_database")] public string StateDatabase { get; set; } = "";
    [JsonPropertyName("database_provider_before")] public string DatabaseProviderBefore { get; set; } = "";
    [JsonPropertyName("database_backup")] public string? DatabaseBackup { get; set; }
    [JsonPropertyName("runtime_latest_provider")] public string? RuntimeLatestProvider { get; set; }
    [JsonPropertyName("runtime_rewrites")] public List<RuntimeRewrite> RuntimeRewrites { get; set; } = [];
    [JsonPropertyName("batch_backup_directory")] public string BatchBackupDirectory { get; set; } = "";
}

internal sealed record RepairOutcome(string SessionId, bool Success, bool Advanced, string? Error);

internal sealed record RepairProgress(int Completed, int Total, string Message);
