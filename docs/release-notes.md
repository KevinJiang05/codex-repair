# v0.6.2 - prerelease

Windows utility for inspecting provider inconsistencies across JSONL metadata,
SQLite thread records, and the latest persisted runtime settings.

Changes:

- Preserve the existing PowerShell 5.1/6/7 compatibility work and script package.
- Refuse open writers and changed content snapshots; retain concurrent content
  instead of overwriting it if replacement is interrupted by another writer.
- Save repair manifests and restore reports before changing conversation state.
- Reject unsupported database schemas and roll JSONL back on database failure
  when the replacement remains protected from writers.
- Use standard .NET self-contained publishing with automatic dependency restore.
- Pin the bundled .NET runtime to 8.0.32 and SQLitePCLRaw to 2.1.14 (SQLite 3.54.0).
- Add regression cases, Windows CI, bilingual documentation, synthetic screenshot,
  project license, bundled license texts, and archive checksums.

Assets:

- CodexRepair-v0.6.2-win-x64.zip and matching .sha256
- CodexRepair-v0.6.2-script.zip and matching .sha256

Close target Codex threads before repair or restore. Backups contain private data.
No full Codex client version has been certified end to end; this prerelease is
validated against synthetic state_5/JSONL fixtures. Provider repair cannot guarantee
successful migration of upstream-bound state. See README for exact limits.
