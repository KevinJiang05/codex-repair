Codex Repair 纯脚本便携版
=========================

适用系统：Windows 10/11 x64
运行依赖：Windows PowerShell 5.1 或 PowerShell 6.x/7.x，以及 Python 3

使用方法：
1. 将整个 ZIP 解压到一个可写目录，不要直接在压缩包内运行。
2. 双击“Codex Repair.cmd”。
3. 首次建议只扫描最近几天，并先选择一个任务验证。
4. 红色任务可普通修复；黄色任务需要显式启用高级修复并二次确认。
5. 修复前关闭对应的 Codex 任务，修复后重新打开验证。

备份：
- 程序会在本便携包根目录自动创建 backups 文件夹。
- backups 可能包含对话 JSONL 和状态数据库快照，请勿公开分享。
- “恢复备份”只能选择当前便携包 backups 目录中的 manifest.json。

依赖检查：
- Windows 自带的 powershell.exe 应为 5.1；安装了 6.x 或 7.x 时也可使用 pwsh.exe。
- 启动器优先使用 PATH 中的 pwsh.exe，找不到时使用 powershell.exe。
- PowerShell 6 可直接运行扫描和修复脚本；图形界面会自动调用 Windows PowerShell 5.1。
- 执行 py -3 --version 或 python --version，应显示 Python 3.x。
- 本工具只使用 Python 标准库，不需要 pip 安装第三方包。

安全说明：
- 程序不会修改 config.toml，只读取其中当前启用的 provider。
- 修复前会备份，SQLite 更新使用事务，JSONL 使用临时文件原子替换。
- 高级修复针对 provider 状态错位，不能保证所有跨 provider 任务都可恢复。

版本：见 VERSION 文件。

预发布兼容范围：
- 当前自动化使用合成 state_5.sqlite/JSONL 数据，未对完整 Codex 客户端版本进行端到端认证。
- 目标来自 config.toml 顶层 model_provider，不解析 profile 或项目覆盖。
- 修复和恢复期间必须保持对应任务关闭；检测到并发变化时可能需要核对已保存的清单。
- JSONL 与 SQLite 为独立存储，不构成一个跨文件事务。
- 许可证：见 LICENSE；便携二进制第三方许可见 THIRD-PARTY-NOTICES.txt 和 licenses。
