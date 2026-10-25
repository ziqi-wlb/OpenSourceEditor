# Markdown、项目搜索与恢复

[English](document-workspace.md)

## Markdown 工作区

`.md`、`.markdown`、`.mdown`、`.mkd` 共用 Edit / Preview / Side by Side 工具栏，每个文件记住自己的模式。切换保留源文本、选区和原生撤销；预览读取未保存文本，并跟随深浅主题。

0.8.2 起 Outline 始终一键显示完整 Preview，含正在渲染、已有预览、并排及没有标题的笔记，无二次菜单、标题选择或 Build 步骤。0.9.2 起 Preview/并排/HTML 导出直接显示正文，不插入 Contents。Markdown 的 ⌘B 和 Tools → Render Markdown 也渲染当前未保存文本，不需要构建配置、编译器或外部命令，也不自动保存；其他语法保留构建流程。

Foundation 拥有块身份、内联属性与源位置。HTML 适配处理标题、段落、嵌套列表、引用、表格、代码、链接、强调和任务框。任务为只读；代码标记语言并转义，不执行。标题 ID 保留，文档写的 `[Next](#next-section)` 可导航而不修改源选区；HTML 导出嵌入样式和本地图片。

只在请求时创建系统 WKWebView。首次立即渲染，后续编辑防抖 250 ms。每个视图拥有串行队列、取消和修订/代次检查；旧结果不能覆盖新文件。Foundation 解析中途不能取消，输入边界约束工作量，转换在块之间检查取消。回到 Edit、切换纯文本或关闭会取消并分离预览。更新保留近似滚动比例，未实现按源码行同步。

渲染状态保持到对应 WebKit 导航完成，空白/过期加载不能标记当前页就绪；仅解析 HTML 不证明 DOM 已显示。加载完成前禁用导出。旧 Outline 待选标题菜单与源码选区导航桥已移除。

预览使用私有、无网络的 `source-editor-preview://document/` origin。锚点对照当前解析标题校验后滚动；真实鼠标测试验证该路由，修复旧 `about:blank` 锚点无效问题。导出只保留普通锚点，不包含私有 origin。

原始 HTML 作为转义文字显示；脚本禁用，不下载远程图片。HTTP/HTTPS/mail 使用系统打开，相对文件链接用编辑器打开。解析符号链接后，本地图片限制在项目根或文件目录。单图 4 MiB、输入总额 12 MiB、4000 万像素；重复图片也消耗 16 MiB 嵌入输出预算。Markdown 上限 200 万 UTF-16 单位、各 100,000 块/样式 run、32 MiB HTML。拒绝预览时源码仍可编辑。公式、Mermaid、内嵌 HTML 和完整 GitHub Markdown 未实现。

## 项目侧栏

0.9.2 打开/切换项目内文件时，展开祖先目录、选中并滚动定位。重选当前标签会恢复手动折叠的路径；保留其他目录展开与编辑焦点。未命名/项目外文件不替换项目和选择。隐藏侧栏保持隐藏，再显示时定位当前文件。明确 Reveal in Side Bar 会显示侧栏，也可定位非活动标签而不切换文档。

自动与明确定位复用 Reveal 的路径遍历所有者，逐组件访问懒加载 children，不递归展开全树。在文件选择、项目变化/刷新、保存和侧栏显示时调用，不在每次光标更新中做目录工作。新路径目录枚举仍同步；没有重新测量超大目录延迟。显示开关与全屏见 [布局与专注模式](layout.zh-CN.md)。

## 项目搜索

Find → Find in Project（⇧⌘F）搜索磁盘文件的字面文本，可选择大小写。结果展示相对路径、逻辑行号与摘录；双击/Return 定位确切范围，提交前对照当前缓冲区，拒绝不再存在的匹配。

Quick Open/搜索共用可取消遍历，规范路径并跳过隐藏文件、包、符号链接、node_modules、__pycache__。上限 50,000 文件、单文件 2 MiB、总读取 128 MiB、2,000 匹配；跳过二进制/不可解码数据并报告容量/跳过范围。项目正则/替换、多根、.gitignore、可配置排除尚未提供。

## 编辑命令

| 操作 | macOS 快捷键 | 行为 |
| --- | --- | --- |
| Markdown 预览 | ⇧⌘V | 源码/预览 |
| 并排 | ⌥⌘V | 原生源码与渲染并排 |
| 项目搜索 | ⇧⌘F | 后台磁盘字面搜索 |
| 注释 | ⌘/ | 当前语法的行/块注释 |
| 复制行 | ⇧⌘D | 合并重叠行并选择副本 |
| 删除行 | ⇧⌘K | 删除选中逻辑行 |
| 移动行 | ⌥↑ / ⌥↓ | 移动选中行组 |

行操作合并重叠选择、保留 Unicode 边界及 LF/CRLF/CR/无尾换行。移动保留各位置行终止符，一次原生撤销含光标恢复。注释保留缩进、跳过空行；JSON/纯文本无注释命令，块分隔符冲突报错且保留文本。这是基本语法操作，并非语法树重构。

## 草稿恢复

0.9.0 默认开启自动备份，Keep Drafts 正常关闭补写最后文本，下次恢复未命名/未完成文件。Discard Drafts 和 Revert 明确返回磁盘原件，备份/恢复不覆盖它。见 [草稿所有权、限制与真实重启](draft-recovery.zh-CN.md)。异常快照通过启动提示/Recovery 选择，损坏文件保留。

## 验证

macOS 0.9.3 在 `bilingual-focus-093-verified` 通过 **646 项检查、13 项合同向量明确跳过**。79 项工作区 UI 保留 Markdown 覆盖，并验证全屏/专注恢复、独立显示开关、原布局持久化、中英文介绍/版本窗口及长文本随窗口宽度换行。完整验收还包含无工作区信息菜单和旧布局元数据兼容。Universal 两切片编译，Intel 版本入口在 Rosetta 执行，原生 GUI 在 Apple Silicon；源码/程序摘要及截图匹配此版本。见 [布局行为](layout.zh-CN.md)。以下资源与验收记录属于对应历史版本。

0.9.2 `preview-sidebar-092` 为 **616 通过、13 明确跳过**。53 项工作区 UI 检查确认正文直接显示、真实鼠标锚点与无 Contents 导出；侧栏检查 Unicode 路径、折叠恢复、可见滚动、焦点、其他展开目录、隐藏/显示和项目外文件。Universal 编译、Rosetta 版本入口通过；GUI 在 ARM 执行。记录生产摘要匹配；未重测大目录延迟或运行内存。

历史 0.8.2 `markdown-render-082-verified`：**560/13**，52 项工作区 UI 覆盖 Outline 所有模式、重复点击、无标题、加载/主题/导出/取消/编辑/撤销和当时的 Contents 点击。

历史 0.8.1 `markdown-render-081-v2`：**557/13**，49 项 UI 覆盖真实 Outline、未保存渲染、撤销、同一构建配置对 Markdown 只渲染/其他语法执行，以及修订后的文本视图和 DOM 加载确认。`isLoading == false` 单独不能证明请求页面就绪。

```sh
bash tests/run_all.sh markdown-render-verification --ui --arch universal
```

生产边界覆盖解析、本地资源、项目容量/取消和 Unicode 行/注释。原生 UI 覆盖转换、导出、旧代次、选区、单次撤销、恢复窗口与清理；独立进程突然退出，再读变化原件/损坏快照。0.7.0 为 450 项、13 跳过，含 34 Markdown UI、6 异常恢复；独立源码包重建相同 Universal 程序并通过 9 服务检查。跳过不是通过。

[产品验收](product-readiness.zh-CN.md)、[WebKit 资源](document-workspace-performance.zh-CN.md)、[文本性能](performance-optimization.zh-CN.md) 说明边界，不能替代 IME、VoiceOver、长期使用和 Intel/Windows 原生验收。

Preferences → Remember Previous Workspace 默认开启，同时恢复文件夹与文件标签。关闭后重开进入空白窗口，保留可手动恢复的草稿与独立的最近文件夹历史。参见[工作区恢复](workspace-restoration.zh-CN.md)。

新窗口和纯文件夹项目显示带快捷操作与最近记录的原生主页，关闭最后一个文件标签后回到主页。通过项目标题/窗口标题栏的侧栏图标或 ⌃⌘B 扩大主区域。参见[工作区主页](workspace-home.zh-CN.md)。
