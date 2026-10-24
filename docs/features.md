# 功能与支持范围

此矩阵描述当前源码提供的能力。macOS 0.9.1 使用 Swift / AppKit；Windows x64 是独立的实验实现。两平台没有完全共享 UI、编辑核心或扩展宿主，不能从 macOS 测试推导 Windows 的功能与稳定性。

| 日常能力 | macOS | Windows |
| --- | --- | --- |
| 文件打开、保存、另存为、全部保存 | 支持，严格编码、磁盘冲突检查、原子替换 | 支持，独立 Win32 实现 |
| 文件页和右键菜单 | 路径/名称/相对路径复制、Finder 定位、保存、关闭等 | 文件页、文本、项目行右键与 Explorer 定位 |
| 多窗口 | 同一应用内窗口标签、分离、合并、活动窗口菜单 | 未提供 macOS 等价工作区 |
| 文本、撤销、重复编辑 | 原生 TextKit；多选事务保留选区 | RichEdit，切换文件页仍重置撤销历史 |
| 多光标、选中下一个、拆分编辑 | 支持，共享文档 storage | 未实现同等能力 |
| 查找与替换 | 单文件字面/正则、后台扫描、完整性检查 | 字面前向搜索、F3 |
| 项目 | 懒加载树、Quick Open、字面搜索、创建/移动/废纸篓、事件刷新 | 懒加载文件树 |
| 行编辑与缩进 | 复制/删除/移动行、注释、tab/空格转换、缩进检测 | 基础 tab/空格宽度设置 |
| 编码/换行 | 状态栏选择编码/BOM、重开编码、LF/CRLF/CR | UTF-8/BOM、UTF-16 LE BOM、LF/CRLF |
| 主题与字体 | 暗色/浅色、字号、已安装等宽字体菜单、自定义配置字体、统一 SF Symbols 按钮 | 暗色/浅色文本外观，功能较少 |
| Markdown 阅读 | Edit / Preview / Side by Side、Outline 一键渲染、Contents、HTML 导出 | 未实现 |
| 工作笔记 | 会议/日报/任务模板、格式、时间戳、列表续写、任务切换、图片粘贴 | 未实现 |
| 最近文件与工作现场 | 最近文件、偏好、项目、文件顺序、布局和选区恢复 | 未实现同等 session 恢复 |
| 未保存草稿 | 默认独立备份、关闭补写、重启恢复、明确丢弃、原件变更保护 | 尚未实现 |
| 构建与扩展 | 指定构建命令、一次性 Python SDK、取消与超时 | 未实现 Python 宿主 |
| 包与安装 | Intel / ARM Universal，用户目录安装、Finder Markdown 关联 | x64 便携 EXE，暂无文件关联安装器 |

## 常用入口

| 任务 | 入口 |
| --- | --- |
| 打开项目文件夹 | File → Open Folder |
| 项目快速打开 | ⌘P |
| 命令面板 | ⇧⌘P |
| 查找 / 项目查找 | ⌘F / ⇧⌘F |
| 保存全部文件 | File → Save All |
| 恢复磁盘内容 | File → Revert File… |
| 保留未保存内容下次继续 | 关闭窗口或退出 → Keep Drafts |
| 查看遗留草稿 | File → Recovery → Find Recovery Snapshots |
| Markdown 预览 / 并排 | ⇧⌘V / ⌥⌘V |
| 一键渲染 Markdown | Outline 或 ⌘B |
| 注释 / 复制行 / 删除行 | ⌘/ / ⇧⌘D / ⇧⌘K |
| 移动行 | ⌥↑ / ⌥↓ |
| 标记任务完成 | ⇧⌘Return |
| 字体与主题 | Preferences → Editor Font / Theme；View → Font 调整字号 |
| 编码、缩进、语法、换行 | 下方状态栏控件 |

更多行为见 [文档工作区](document-workspace.md)、[草稿恢复](draft-recovery.md)、[日常笔记](daily-use-implementation.md) 和 [扩展](../plugins.md)。

## 尚未完整支持

完整 TextMate/Sublime 语法、片段、LSP 补全/诊断、矩形选择、minimap、项目正则替换与未保存文本搜索、Git 差异视图、内置终端、Markdown 公式/Mermaid/PDF、预览直接编辑任务、通用插件兼容、签名公证与自动更新尚未齐备。

中文/日文真实输入法、VoiceOver、长时间连续编辑、多屏/全屏/睡眠唤醒、Intel 实机和 Windows 原生 GUI 仍需专项验收。自动测试通过与功能存在不能作为“所有功能完整”或工业级认证。后续任务和验收标准见 [产品就绪清单](product-readiness.md)。
