# Usage and development guide

[Project overview](../README.en.md) · [简体中文](usage.md)

## Download and use

Choose an archive from [Releases](https://github.com/KevinJiang05/codex-repair/releases):

| Archive | Requirements |
| --- | --- |
| CodexRepair-vVERSION-win-x64.zip | Bundles .NET; no separate PowerShell, Python, or .NET installation |
| CodexRepair-vVERSION-script.zip | Windows PowerShell 5.1 or PowerShell 6/7, plus Python 3 |

1. Extract the entire ZIP into a writable directory and launch **Codex Repair.cmd**.
2. Check the target provider and scan a short date range. Scanning does not change threads.
3. Close the target Codex threads and keep them closed throughout repair or restore. Verify one thread first.
4. Red rows allow standard repair. Yellow rows need inspection: runtime conflicts require enabling advanced repair and two confirmations; missing or invalid files are blocked.
5. Reopen the thread and verify its actual behavior.

Advanced repair changes only the latest effective runtime-provider event. Matching provider fields cannot guarantee that every cross-provider thread can resume.

The current binaries are not code-signed.

## How it works

The scanner compares:

| Store | Field |
| --- | --- |
| First JSONL session_meta record | payload.model_provider |
| threads table in state_NUMBER.sqlite | model_provider |
| Latest thread_settings_applied event | payload.thread_settings.model_provider_id |

The target comes from the top-level model_provider in the selected Codex directory's config.toml, defaulting to openai. Profile, project, and command-line overrides are not resolved; inspect the displayed target before proceeding.

SQLite updates use transactions and expected-value checks. JSONL is replaced through a verified temporary file while preserving mtime. Backups and a restore manifest are saved before mutation; an unwritable manifest refuses repair. Open writers and stale content snapshots are rejected.

The JSONL file and SQLite database are separate stores, with no single transaction spanning both. If another writer intervenes after replacement, concurrent content is retained and failure is reported; close the thread and inspect the saved recovery information.

## Restore and privacy

Use the restore button to select a thread's manifest.json inside this copy's backups directory. Restore reverts the provider fields changed by this tool, preserves ordinary appended conversation records, and refuses newer runtime settings. It never replaces the live database with an old whole-database snapshot.

Backups can contain complete conversations, titles, absolute paths, and database snapshots. Keep them private. Issues should contain redacted errors and synthetic reproductions, without original JSONL, SQLite, backups, or configuration files.

The application reads configuration and conversation files locally. It does not extract, display, or upload credentials, and does not change config.toml. Building downloads dependencies from NuGet.

## Compatibility

- Targets Windows 10/11 x64. See the [validation record](publish-preview.md) for the actual local validation environment.
- Automated fixtures use state_5.sqlite with id, rollout_path, created_at, model_provider, title, and archived columns, plus the JSONL shapes above.
- Missing required columns cause an explicit refusal. A database number alone does not establish compatibility.
- The GUI defaults to the user's .codex directory. PowerShell scripts accept an explicit -CodexHome; custom CODEX_HOME discovery in the C# GUI is not implemented.
- No complete Codex client version has been certified end to end. Other schema versions, remote/cloud histories, and different event shapes need separate verification.
- Script regressions cover Windows PowerShell 5.1 and PowerShell 7. The retained PowerShell 6 GUI entry delegates to Windows PowerShell 5.1; version 6 was not revalidated in this release.

## Build and verify

The script version uses Python's standard-library sqlite3 module. The self-contained package requires Windows, PowerShell 7, and a .NET 8 SDK to build. A first build restores NuGet dependencies automatically.

```powershell
pwsh -NoProfile -File .\scripts\repair-gui.ps1 -ScanOnly -AllDates -SummaryOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke.ps1
pwsh -NoProfile -File .\tests\smoke.ps1
dotnet build .\src\CodexRepair.Portable\CodexRepair.Portable.csproj -c Release
dotnet .\src\CodexRepair.Portable\bin\Release\net8.0-windows\CodexRepair.dll --self-test
pwsh -NoProfile -File .\scripts\build-script-package.ps1
pwsh -NoProfile -File .\scripts\build-portable.ps1
pwsh -NoProfile -File .\tests\release.ps1
```

Archives and archive checksums are written to dist. The self-contained runtime version is pinned in the project file. Windows CI reuses the same regressions and package checks.

Tests use synthetic data for standard/advanced repair, restore, appended-content retention, backups, mtime, open writers, stale snapshots, manifest failure, database rollback, and unsupported schemas.

Source layout: src/CodexRepair.Portable contains the WinForms application and self-tests; scripts contains the PowerShell implementation and builders; tests contains regressions and archive verification.

## License

[MIT](../LICENSE). Bundled component notices and license texts are included in [THIRD-PARTY-NOTICES.txt](../THIRD-PARTY-NOTICES.txt) and licenses/.
