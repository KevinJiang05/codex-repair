# 使用与开发指南

[返回项目介绍](../README.md) · [English guide](usage.en.md)

## 下载与使用

在 [Releases](https://github.com/KevinJiang05/codex-repair/releases) 中选择发布包：

| 发布包 | 运行依赖 |
| --- | --- |
| CodexRepair-v版本-win-x64.zip | 内置 .NET 运行时，无需另外安装 PowerShell、Python 或 .NET |
| CodexRepair-v版本-script.zip | Windows PowerShell 5.1 或 PowerShell 6/7，以及 Python 3 |

1. 将完整 ZIP 解压到可写目录，双击 **Codex Repair.cmd**。
2. 核对界面中的目标 provider，先扫描最近几天。扫描不修改任务。
3. **关闭将要修复的 Codex 任务，确保修复期间不再写入。** 先选择一个任务验证。
4. 红色任务可普通修复；黄色任务需查看具体状态，只有运行时冲突可在启用高级修复、两次确认后处理。缺失或无效文件会被阻止。
5. 修复后重新打开任务，验证实际恢复情况。

高级修复只调整最后一条生效的运行时 provider，更早的历史记录保持原样。provider 字段一致不代表所有跨 provider 会话都能恢复。

当前二进制尚未进行代码签名。

## 检查与修复原理

| 存储位置 | 检查字段 |
| --- | --- |
| 会话 JSONL 第一条 session_meta | payload.model_provider |
| state_数字.sqlite 的 threads 表 | model_provider |
| 最后一条 thread_settings_applied 事件 | payload.thread_settings.model_provider_id |

目标来自所选 Codex 目录 config.toml 的顶层 model_provider，未设置时为 openai。工具不解析 profile、项目配置或命令行覆盖，使用前需核对目标。

- SQLite 更新使用事务和原值条件，单个数据库每批次备份一次。
- JSONL 通过验证过的临时文件原子替换，保留原修改时间。
- 写入前保存恢复清单和对应备份；无法保存清单时拒绝修复。
- 检测到已打开的写句柄或检查后的内容变化时拒绝写入。
- JSONL 与 SQLite 是两个独立存储，不构成同一个跨文件事务。若替换后出现新的写入，会保留并发内容并报告失败，需关闭任务后核对备份恢复。

## 恢复与隐私

点击“恢复备份”，选择当前工具目录 backups 中对应任务的 manifest.json。恢复只撤销本工具修改的 provider 字段，不以旧快照覆盖整库；会保留修复后追加的普通对话。如果出现更新的运行时设置，则拒绝恢复。

备份默认位于工具根目录 backups；PowerShell 修复脚本支持 -BackupRoot。恢复前也应关闭相关任务。

**备份可能包含完整对话、任务标题、绝对路径和数据库快照，请勿上传或公开分享。** 提交 issue 时只提供脱敏错误与版本，不附原始 JSONL、SQLite、备份或配置文件。

程序读取配置和会话文件以完成本地检查，不提取、展示或上传认证信息，不修改 config.toml。构建时会从 NuGet 下载依赖。

## 兼容范围

| 项目 | 范围 |
| --- | --- |
| 目标平台 | Windows 10/11 x64；本地验证环境与结果见 [验证记录](publish-preview.md) |
| 自动化数据 | 合成 state_5.sqlite，包含 id、rollout_path、created_at、model_provider、title、archived |
| JSONL 格式 | session_meta 与上述 thread_settings_applied 事件形状 |
| 存储目录 | 默认读取用户目录下 .codex；PowerShell 脚本可显式传入 -CodexHome；C# GUI 尚不自动识别自定义 CODEX_HOME |
| 未认证范围 | 尚未对某个完整 Codex 客户端版本进行端到端兼容认证；多版本、远程/云会话及不同事件格式需单独验证 |

数据库编号本身不代表兼容；缺少所需字段时会明确拒绝处理。PowerShell 6 的 GUI 会转交系统 Windows PowerShell 5.1；本轮自动化覆盖 5.1 和 7，6 的兼容入口保留但未重新实测。

## 从源码运行与构建

脚本版需要 Python 3（仅使用标准库 sqlite3）。根目录的 Codex Repair.cmd 启动脚本界面。

```powershell
# 只读扫描；自定义目录可添加 -CodexHome <路径>
pwsh -NoProfile -File .\scripts\repair-gui.ps1 -ScanOnly -AllDates -SummaryOnly

# 模拟数据回归，不读取真实 Codex 任务
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke.ps1
pwsh -NoProfile -File .\tests\smoke.ps1
```

便携版构建需要 Windows、PowerShell 7 和 .NET 8 SDK，首次构建需要联网恢复 NuGet 依赖，无需预先生成 obj 文件或手工复制运行时。

```powershell
dotnet build .\src\CodexRepair.Portable\CodexRepair.Portable.csproj -c Release
dotnet .\src\CodexRepair.Portable\bin\Release\net8.0-windows\CodexRepair.dll --self-test
pwsh -NoProfile -File .\scripts\build-script-package.ps1
pwsh -NoProfile -File .\scripts\build-portable.ps1
pwsh -NoProfile -File .\tests\release.ps1
```

两个 ZIP 及各自的 .sha256 输出到 dist。便携版使用标准自包含发布，运行时版本固定在项目配置中。GitHub Actions 的 Windows 流程复用上述回归和发布检查。

普通修复、高级冲突、追加内容保留、备份、时间戳、写句柄占用、过期内容快照、清单失败、数据库失败回退和未知结构拒绝均有合成数据回归。

## 项目结构与维护

- src/CodexRepair.Portable：C# / WinForms 便携版及引擎自检。
- scripts：PowerShell 界面、修复、恢复、共享会话 I/O 与打包脚本。
- tests：脚本回归和发布包验证。
- docs：合成截图、验证记录与使用说明。

适合提交问题的材料：工具版本、Windows/PowerShell 版本、脱敏错误及最小合成复现。客户端格式变化时先更新诊断与测试，再决定是否支持写入。

本项目采用 [MIT License](../LICENSE)。便携版第三方组件及许可见 [THIRD-PARTY-NOTICES.txt](../THIRD-PARTY-NOTICES.txt) 和 licenses 目录。
