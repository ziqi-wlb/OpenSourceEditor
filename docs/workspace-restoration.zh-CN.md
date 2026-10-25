# 记住上次工作区（macOS 0.9.4）

[English](workspace-restoration.md)

**Preferences → Remember Previous Workspace（记住上次工作区）** 默认开启。正常启动会恢复此前的文件夹、已保存文件标签、选区、Markdown 显示模式与普通窗口布局；只打开文件夹、没有文件标签的窗口也能恢复。侧栏保留已展开的目录、选中项和滚动位置。关闭最后一个窗口后从 Dock 重开，会恢复最后关闭的工作区；File → New Window 仍创建新窗口。

| 设置或操作 | 行为 |
| --- | --- |
| 开启 Remember Previous Workspace | 恢复已保存的打开窗口；全部关闭时恢复最后关闭的工作区 |
| 关闭 Remember Previous Workspace | 清空普通恢复元数据，下次进入空白窗口 |
| File → Reopen Last Folder | 打开最近成功打开的文件夹，不受该开关影响 |
| File → Open Recent Folders | 选择最多 20 个最近文件夹之一，或清空文件夹历史 |
| 启动时明确指定文件或文件夹 | 打开指定内容；历史工作区可通过最近记录或恢复入口访问 |
| 关闭/退出 → Keep Drafts | 将最终未完成内容写入独立备份，不覆盖原文件 |

开关也可从命令面板访问，全部编辑窗口关闭后仍可使用设置菜单。规范配置键为 `"remember_workspace": true`，旧配置没有该键时默认为开启。最近文件与最近文件夹分别存储。历史文件夹不可用时显示提示，保留当前项目。

关闭开关会停止工作区和保留草稿的自动重开，**不会删除草稿备份或最近文件夹记录**。可通过 File → Recovery → Find Recovery Snapshots 手动查看。定时草稿备份是另一个设置；即使关闭定时备份，Keep Drafts 仍捕获最终编辑。Save 与 Revert 保持明确保存与恢复原件的语义。参见[草稿恢复](draft-recovery.zh-CN.md)。

`EditorAppDelegate` 持有已解析的桌面状态、开关与最近文件夹操作。`SavedDesktop.workspaces` 描述打开的窗口，可选 `lastClosedWorkspace` 保留最后关闭的工作区，避免关闭最后窗口清空项目。仍打开的窗口优先恢复，因此普通关闭的干净窗口不会随剩余窗口重新出现；明确保留的草稿仍可恢复。

`EditorWorkspace` 持有相对项目路径的侧栏状态与布局恢复。展开操作通过现有懒加载树读取保存的可见祖先。草稿恢复重建文档视图和目录树后，重新应用布局，不重读源文件。不增加定时器或后台线程。桌面 JSON 上限为 1 MiB、32 个打开窗口和 256 个已保存文件标签；最后关闭窗口独立限制为 256 个标签。验证拒绝无效相对路径及非有限几何值，保留可选字段兼容、原子替换和 `.previous` 备份机制。

UI 验收覆盖真实菜单操作、纯文件夹关闭/Dock 重开、Unicode 目录展开、隐藏控件、明确输入、缺失目录和多窗口优先级。`tests/workspace_restart_test.py` 启动不同 AppKit 进程，分别验证关闭最后窗口、正常 Keep Drafts 退出与关闭恢复开关，使用临时支持目录检查布局、草稿和原文件字节不变。这些检查验证对应 macOS 行为，不覆盖跨进程撤销历史、实体 Intel GUI、Windows 等价能力或断电持久性；没有新增延迟或内存实测结论。

参见[开发指南](development.zh-CN.md)、[架构](architecture.zh-CN.md)、[布局](layout.zh-CN.md)和[版本说明](../RELEASE_NOTES.zh-CN.md)。

最终 `workspace-094-final` 验收为 708 项通过、13 项合同向量明确跳过，其中包含 20 项原生工作区和 32 项独立进程检查。通过验收的 Universal 发行程序和源码摘要匹配 macOS 0.9.4；工作区恢复图片由原生内容视图捕获。
