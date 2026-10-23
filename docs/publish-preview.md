# v0.6.2 发布验证记录

核验日期：2026-10-23。以下为发布前完成的本地验证记录；Windows CI 和发布资产可从仓库 Actions 与 Release 页面核对。

## 已完成的改动

- 保留并纳入之前未提交的 PowerShell 5.1/6/7 兼容工作及脚本分发入口。
- 源码和程序集版本统一读取 VERSION：0.6.2。
- 写入前持有拒绝其他写句柄的会话读句柄；PowerShell 对比检查前后的完整内容摘要。
- JSONL 原子替换后重新取得保护句柄并校验内容；若期间出现新写入，保留内容并报告失败。
- 修复 manifest 和恢复报告先保存，再修改会话状态；清单保存失败会拒绝操作。
- 数据库更新失败且替换文件仍受保护时，以原字节原子回退 JSONL，保留时间戳。
- 拒绝缺少必要字段的数据库；目标 provider 只从顶层配置识别，支持行尾注释，拒绝无法识别的显式语法。
- 标准 .NET self-contained 发布自动恢复依赖，移除开发机特定启动路径和运行时拼装步骤。
- 补中英文 README、合成截图、MIT 许可证、第三方许可文本、校验和与 Windows CI 配置。

## 本地验证结果

环境：Windows 11 企业版 10.0.26200 x64；.NET SDK 8.0.303；Python 3.12.10。

| 验证 | 结果 |
| --- | --- |
| Windows PowerShell 5.1.26100.9711，tests/smoke.ps1 | 通过 |
| PowerShell 7.6.3，tests/smoke.ps1 | 通过 |
| C# Release 构建 | 通过，0 警告、0 错误 |
| C# 引擎自检 | 通过，包括写句柄占用、清单失败、数据库失败回退、时间戳、追加内容和未知结构 |
| 目标配置测试 | 嵌套 profile 不误认顶层 provider；行尾注释可识别 |
| 最终两个分发包内置自检/语法检查 | 通过；便携包使用无效 DOTNET_ROOT 仍可运行自检 |
| 干净源码快照构建 | 在含空格的新目录中，初始无 bin、obj、dist、backups 或 .git，两个包均成功构建 |
| tests/release.ps1 | 通过；脚本包 9 项内容校验，便携包 479 项内容校验 |
| 发布包内容 | 未包含会话、数据库、备份、调试符号；脚本包没有 EXE/DLL |
| 常见凭据与个人绝对路径模式筛查 | 当前 Git 可见源码未发现匹配；初始主分支提交已在评估阶段筛查 |
| Git 历史元数据 | 评估时的初始主分支提交使用 GitHub noreply 作者/提交者邮箱 |
| Git diff 空白检查 / PowerShell 语法解析 | 通过 |
| NuGet 已知漏洞检查 | 当前源未列出易受攻击的依赖包 |

脚本测试日志中的 fixture database failure 与 Unsupported schema 是主动注入的预期失败，最终退出码为 0。

上述验证只使用合成配置、会话和数据库；没有读取或修改真实 Codex 会话或用户配置。

干净源码快照来自当前 Git 可见文件，验证时未执行远端 git clone。它复现了无构建产物的首次恢复与构建，但没有测试网络隔离或无全局 .NET 的裸机。运行包的 includedFrameworks 已确认为 8.0.32。

## 依赖与发布资产

保留 Microsoft.Data.Sqlite 8.0.8。原有 SQLitePCLRaw 原生组件 2.1.6 被 NuGet 标为高危；现固定现有组件系列为 2.1.14，实际 SQLite 为 3.54.0。自包含 .NET / Windows Desktop 运行时为 8.0.32，无全局 SDK 或运行时升级。

| 本地 dist 文件 | 大小（字节） | SHA-256 |
| --- | ---: | --- |
| CodexRepair-v0.6.2-win-x64.zip | 73,474,434 | 6f63755b2e2788fc69282bb39940bbbb875f9f8e58f418a9342933f38d2045d4 |
| CodexRepair-v0.6.2-script.zip | 25,452 | 757b6e293fa8d9f8a95692a366e318ddd6ff86866f8d1789ba52bd7860cae662 |

每个 ZIP 对应的 .zip.sha256 已生成，包内 SHA256SUMS.txt 覆盖全部文件（校验清单自身除外）。旧版 0.6.0 和 0.6.1 发布包保留。

## 仍需保留的边界

- 未对任何完整 Codex 客户端版本进行端到端认证；目前可核验的自动化范围是合成 state_5/JSONL 格式。
- Windows 10 与 PowerShell 6 未在本轮重新实测；本地验证不代替托管 CI 结果；Windows 流程见仓库 Actions。
- JSONL 与 SQLite 没有单一跨文件事务。必须关闭目标任务，并在操作期间保持关闭；并发介入后应核对备份和报错，不能把失败等同于完全未改动。
- provider 一致不能保证上游绑定状态能够迁移；二进制尚未代码签名。
- 源码筛查是常见模式检查；备份本身包含私有内容，必须继续排除在 Git 和公开附件之外。

## 相关文档

- [项目介绍](../README.md) / [English](../README.en.md)
- [使用指南](usage.md)
- [合成界面截图](images/overview.png)
- [Release 说明](release-notes.md)
- [Windows CI](../.github/workflows/windows.yml)
