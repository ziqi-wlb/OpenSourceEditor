# 草稿备份与重启恢复（macOS 0.9.0+）

[English](draft-recovery.md)

自动备份写入应用自己的恢复目录，**不会覆盖编辑中的原文件**。只有显式 Save / Save All 才写入源文件。已保存文件、项目和显示布局仍由正常工作区状态记录；未保存文本由独立草稿负责。

## 日常使用

| 操作 | 结果 |
| --- | --- |
| 默认编辑 | 自动恢复默认开启，每 5 秒检查未保存文档；内容、编码、缩进设置和选区写入独立 JSON |
| 关闭窗口 / 退出应用 → Keep Drafts | 捕获最后编辑状态，等待写入完成，再关闭；保留原文件 |
| 下次正常启动（已开启记住上次工作区） | 自动恢复保留的草稿、未命名笔记，并保留已保存文件页；无需先将笔记另存为文件 |
| 最后窗口关闭后点击 Dock（已开启记住上次工作区） | 恢复最后关闭的文件夹、布局与保留的草稿；File → New Window 仍创建新工作区 |
| 关闭 → Save All | 正常保存文件；未命名文件显示保存对话框，取消或保存失败会中止关闭 |
| 关闭 → Discard Drafts | 删除当前窗口的恢复数据，不写入原文件；下次读取磁盘原文件 |
| 关闭 → Cancel | 留在当前编辑器，缓冲区和编辑能力继续可用 |
| 恢复后 File → Revert File… | 确认后丢弃当前文件草稿，重新读取磁盘文件，并清除该文件的备份内容 |
| File → Recovery → Find Recovery Snapshots | 每个快照提供 Restore Drafts、Discard Drafts and Open Originals、Later；Later 不删除备份 |
| 单独关闭文件页 | 保留原来的 Save / Don't Save / Cancel 语义；Don't Save 明确丢弃该页，并更新恢复快照 |

“保留草稿”即使关闭了周期自动恢复也可使用。关闭周期恢复会清理该窗口已有的自动快照；如仍要保留当前编辑，请在关闭时选 Keep Drafts，或手动 Save Session。

## 存储与所有权

默认目录为 `~/Library/Application Support/Source Editor/Recovery/`，每个工作区拥有一个随机命名的 JSON 文件。父目录权限为 `0700`，快照为 `0600`。工作区元数据和偏好位于上级目录，更新前保留 `.previous`；JSON 采用原子替换。

`EditorRecovery` 拥有串行后台队列。正常写入期间的新请求合并为最后一份待写状态；关闭时停止周期计时器，冻结编辑并捕获最终快照。最终状态覆盖尚未开始的周期请求，等待正在进行的写入后再持久化。关闭完成回调解除活跃快照登记，应用等所有窗口完成后才真正退出。保留与删除共用队列，避免旧写入在丢弃后重新生成文件。

`EditorSession` 的可选 `closedNormally` 标记区分明确保留的正常退出草稿与异常退出快照。正常启动自动恢复前者；后者通过启动提示和 Recovery 菜单由用户选择。可选工作区信息记录项目、文件页和显示状态；旧版 session 和恢复文件仍可读取。`SavedWorkspace.recoveryFileName` 只允许单个 JSON 文件名，关联正常工作区和独立草稿。

恢复时先校验源文件的 SHA-256 与备份记录。原文件未变更时，草稿保留文件路径，并仍标记为未保存；文件变更或丢失时，草稿成为未命名文档。已恢复的草稿必须写入新的独立备份后，才删除应用恢复目录中的旧备份，避免恢复中断导致唯一副本消失。手动选择的外部 session 文件会保留原始字节；后续自动备份写入应用自己的恢复目录，不在导入文件旁创建或覆盖备份。

选择丢弃并打开原文件时，先读取所有有路径的源文件；读取失败保留备份并报告错误。未命名草稿没有磁盘原件，丢弃会删除其内容。损坏快照不自动删除。备份写入失败会取消关闭，重新允许编辑，并保留快照所有权，可解决磁盘问题后重试。

## 容量与边界

- 每个窗口最多自动备份 128 个修改文档、合计 4 Mi UTF-16 单位，编码后的 session 上限为 32 MiB；未修改的大文件不复制到草稿数据。
- 容量或写入失败显示通知，保留上一次成功快照；关闭时不能把旧快照当作最新备份。可选择 Save All、手动 Save Session 或明确丢弃。
- 每 5 秒的自动检查存在崩溃恢复间隔。正常关闭会补写最终状态，但原子替换不代表断电后的硬件持久性保证。
- 文本、选区、编码和文档设置可恢复；原生 undo 历史不跨进程保存。
- 这是 macOS 功能。Windows 原生版本尚未实现同等的草稿退出与重启恢复。

## 验证

```sh
bash tests/run_all.sh draft-recovery --ui --arch universal
# 已构建测试应用时，单独重跑真实进程退出与重启：
python3 tests/recovery_restart_test.py '.build/Source Editor Tests.app/Contents/MacOS/source-editor'
```

`DraftRecoveryUITests` 使用真实原生窗口、关闭确认 sheet 和隔离的临时支持目录，覆盖最后编辑、未命名文档、正常关闭恢复、取消、Revert、丢弃、外部文件变化、损坏备份、磁盘失败及重试。独立 Python 测试启动真实 AppKit 进程、通过 `NSApplication.terminate` 退出，再启动新进程验证两个窗口的文本、干净文件页、选区和源文件未被覆盖。现有异常退出测试继续验证崩溃恢复。

原始日志保存在忽略的 `.build/test-results/`。Universal 编译覆盖 Intel 和 Apple Silicon 的切片；此工作区的原生 UI 测试在 Apple Silicon 执行，未代替 Intel 实机或 Windows GUI 验收。

0.9.0 本地 `draft-final` 完整回归通过 598 项检查，13 项明确跳过；新草稿/字体 UI 为 23 项，真实正常退出/重启为 15 项。写入耗时、包大小和运行内存见 [本轮资源报告](release-090-performance.zh-CN.md)。

0.9.1 保留手动导入的外部 session，自动备份仅写入应用自有恢复目录；新增原生 UI 检查确认来源文件字节完全保留。

Preferences → Remember Previous Workspace 默认开启，同时恢复文件夹与文件标签。关闭后重开进入空白窗口，保留可手动恢复的草稿与独立的最近文件夹历史。参见[工作区恢复](workspace-restoration.zh-CN.md)。
