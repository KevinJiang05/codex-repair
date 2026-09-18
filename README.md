# Codex Repair

用于扫描并修复 Codex 历史任务中 `model_provider` 不一致的问题。项目同时保留可审查的 PowerShell 原型和面向团队分发的自包含 Windows 便携版。

## 团队分发

推荐分发 `dist` 中自动生成的 ZIP，而不是直接压缩项目目录。便携包内置 Windows x64 的 .NET 桌面运行时，成员不需要安装 PowerShell、Python 或 .NET Runtime。

开发机双击：

```text
Build Portable Package.cmd
```

或执行：

```powershell
pwsh -NoProfile -File .\scripts\build-portable.ps1
```

输出：

```text
dist\CodexRepair-v版本-win-x64\
dist\CodexRepair-v版本-win-x64.zip
```

发布脚本只打包应用、内置运行时、启动入口、便携说明、版本、第三方声明和 SHA-256，不会包含项目中的 `backups`、测试数据、JSONL 或 SQLite。团队成员必须完整解压 ZIP，然后双击唯一入口 `Codex Repair.cmd`。

## 功能

- 扫描全部任务或指定日期范围。
- 同时检查任务 JSONL 头、Codex Desktop 状态数据库，以及最后一次 `thread_settings_applied` 运行时设置。
- 默认只显示需要修复的任务。
- 普通可修复项显示为红色；运行时冲突显示为黄色，默认不会自动勾选。
- 勾选“启用黄色高级修复”后，可以批量修复黄色任务；写入前会进行两次确认。
- 高级修复只改最后一条生效的 `thread_settings_applied` provider，更早的历史记录保持不变。
- 自动读取用户级 `~/.codex/config.toml` 当前启用的 provider，但不会修改配置文件。
- 同时兼容普通任务与已归档任务。
- JSONL 使用临时文件验证后原子替换，并保留原修改时间。
- 每次写入前创建备份并在写入后验证；同一批次只创建一份状态数据库快照。
- 支持从任务 `manifest.json` 定点恢复，不整库覆盖，也不会删除修复后追加的普通对话记录。
- 修复任务在独立后台进程执行，GUI 持续显示进度，不会因大 JSONL 阻塞窗口消息循环。

## 启动

普通用户只需要双击根目录中的唯一入口：

```text
Codex Repair.cmd
```

以上入口是源码版。团队成员应使用发布 ZIP 中的同名 `Codex Repair.cmd`，不要从压缩包内直接运行，也不要单独复制入口文件。

也可以在命令行执行只读扫描：

```powershell
pwsh -File .\scripts\repair-gui.ps1 -ScanOnly -AllDates
pwsh -File .\scripts\repair-gui.ps1 -ScanOnly -FromDate 2026-09-01 -ToDate 2026-09-15
pwsh -File .\scripts\repair-gui.ps1 -ScanOnly -AllDates -SummaryOnly
```

目录结构：

```text
codex-repair\
├── Codex Repair.cmd
├── Build Portable Package.cmd
├── src\CodexRepair.Portable\
├── scripts\
│   ├── repair-core.ps1
│   ├── repair-batch.ps1
│   ├── repair-gui.ps1
│   └── restore-core.ps1
├── PORTABLE_README.txt
├── THIRD-PARTY-NOTICES.txt
├── tests\
│   └── smoke.ps1
├── backups\             # 首次修复时自动创建，不纳入 Git
├── README.md
└── VERSION
```

`repair-core.ps1` 是单任务修复引擎，`repair-gui.ps1` 负责扫描、选择和批量调度。它们属于内部实现，不需要用户分别启动。

## 黄色任务高级修复

1. 扫描任务。
2. 勾选“启用黄色高级修复”。
3. 点击“勾选可自动修复”，或手动选择黄色任务。
4. 点击“修复勾选项”，核对两次确认信息。

高级修复会同步 JSONL 头、状态数据库，以及最后一条生效的运行时 provider。它不会把所有历史 provider 记录批量替换。修复完成后应重新打开任务验证；某些任务还可能包含与原上游绑定的状态，因此不能保证所有跨 provider 任务都能恢复。

修复开始后，底部日志会显示后台进度。修复期间扫描、恢复和再次修复按钮会暂时禁用，但窗口仍可正常移动和重绘。完成后点击“扫描”刷新列表。

## 恢复备份

点击“恢复备份”，选择对应任务目录中的 `manifest.json`。恢复操作会：

- 只撤销该任务由本工具修改的 provider 字段；
- 恢复前再次保存当前 JSONL 和状态数据库快照；
- 如果任务在修复后写入了新的运行时设置，则拒绝恢复，避免覆盖较新的状态；
- 不使用旧 SQLite 快照整库覆盖当前数据库。

恢复前请关闭对应 Codex 任务，恢复后重新打开。

## 备份位置

当前版本面向便携使用，把未来生成的备份统一放在项目目录中：

- 根目录：`codex-repair\backups\`。
- 单任务命令使用一个 `时间戳-任务ID` 子目录。
- GUI 批处理使用一个 `时间戳-batch-数量` 子目录，其中状态数据库只快照一次，每个任务单独保存 JSONL 备份与 `manifest.json`。
- 批处理目录还会生成 `batch-report.json`，记录每项成功或失败。

核心脚本仍支持通过 `-BackupRoot` 指定其他位置。如果程序位于只读 U 盘或无写权限目录，应改用可写路径。

早期版本已经生成在 `~\.codex` 内的旧备份不会自动移动或删除，避免影响恢复能力。

## 安全边界

- 扫描按钮只读，不会修改任务。
- 不读取或显示 API Key、Cookie 等凭据。
- 不修改 `config.toml`。
- 只更新用户明确勾选的任务。
- 数据库更新使用事务；JSONL 写入失败时会恢复其备份。
- 若最后一次持久化运行时 provider 与目标不一致，普通模式不会修改；只有用户显式启用高级模式并二次确认后，才改写最后一条生效记录。
- 如果相关任务正被 Codex 独占写入，修复会安全失败；关闭该任务后重新扫描、修复即可。
- 大 JSONL 以单个二进制缓冲区处理，避免 PowerShell 把每个字节展开为独立对象造成异常内存占用。
- 建议先按日期扫描并核对标题，不要默认迁移全部历史任务。

运行时冲突并不一定只靠 provider 字段就能恢复。例如任务内容可能还带有特定上游生成的状态，因此高级修复仍需逐批验证。

## 源码版依赖

- Windows
- PowerShell 7
- Python 3（使用标准库 `sqlite3`，无需安装第三方包）

开发自检（只在系统临时目录创建模拟数据，不接触真实 Codex 任务）：

```powershell
pwsh -NoProfile -File .\tests\smoke.ps1
```

## 后续计划

1. 针对不同 Codex 状态数据库版本做兼容性测试。
2. 增加备份浏览、详情预览和批次恢复体验。
3. 后续如具备代码签名证书，可给便携程序签名以减少 Windows SmartScreen 提示。

Codex 的任务对象会持久化 `modelProvider`，恢复任务会从已保存的任务状态继续；用户级 `model_provider` 是本工具当前目标 provider 的来源。相关结构可参考 [Codex App Server](https://learn.chatgpt.com/zh-Hans/docs/app-server) 与 [配置参考](https://learn.chatgpt.com/zh-Hans/docs/config-file/config-reference)。CC Switch 当前仍有关于恢复任务时旧 provider 被重新应用的[公开问题记录](https://github.com/farion1231/cc-switch/issues/5922)，因此工具把运行时层单独列出，而不是只比较 JSONL 头和数据库。
