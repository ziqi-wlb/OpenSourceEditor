# Source Editor

[English](README.md)

独立实现的 macOS 原生文本编辑器。此目录可以单独构建和运行，不依赖 Sublime Text、REA、npm、网络或逆向资料。Windows 原生实现见 [Windows](windows/README.zh-CN.md)。

[文档导航](docs/README.zh-CN.md) · [架构与原理](docs/architecture.zh-CN.md) · [功能矩阵](docs/features.zh-CN.md) · [开发与贡献](docs/development.zh-CN.md) · [版本说明](RELEASE_NOTES.zh-CN.md)

**View → Toggle Focus Mode**（`⌥⌘Z`）隐藏编辑控件并进入原生全屏，在正文编辑时按 Escape 恢复之前布局。侧栏、文件标签、状态栏和行号也可在 View 菜单中分别显示或隐藏。全屏下鼠标移到屏幕顶部可访问自动隐藏的菜单栏。见 [布局与持久化](docs/layout.zh-CN.md)。

## macOS 构建与安装

需要 macOS 13+ 和 Xcode Command Line Tools（`xcode-select --install`）。Python 3 只用于扩展。从本目录执行：

```sh
bash scripts/install_macos.sh universal  # 构建、安装到用户 Applications、注册并启动
bash build.sh --arch universal          # 仅构建 Intel/ARM Universal
open '.build/Source Editor.app'
bash package.sh universal               # 独立应用 ZIP
```

也可使用 `--arch arm64` 或 `--arch x86_64`。解压 ZIP 后将 Source Editor.app 拖入 Applications；当前用户安装不需要管理员权限：

```sh
mkdir -p "$HOME/Applications"
cp -R '.build/Source Editor.app' "$HOME/Applications/"
open "$HOME/Applications/Source Editor.app"
```

当前应用未签名、未公证。下载版本可使用 Finder“打开”和系统确认；打包不会改变安全设置或默认编辑器。更新前请保存并用 ⌘Q 退出所有运行副本，关闭窗口并不等于退出应用。安装器拒绝覆盖运行中的应用，并将旧版保存在 `.build/install-backups/`。

安装器注册 Launch Services，为 `.md`、`.markdown`、`.mdown`、`.mkd` 和文本提供 Finder“打开方式”。已有菜单可能需要关闭重开；也可通过“打开方式 → 其他”选择安装的应用。它不会替换系统默认编辑器。

```sh
'.build/Source Editor.app/Contents/MacOS/source-editor' --project . README.md
'.build/Source Editor.app/Contents/MacOS/source-editor' --help
'.build/Source Editor.app/Contents/MacOS/source-editor' --version
```

## 多窗口

File → New Window（⌘⇧N）在同一应用中创建工作区，默认合并为原生窗口标签，Dock 只有一个应用图标。每个工作区独立拥有文档、项目、选区和撤销；菜单跟随当前工作区，字体与主题全局共享。

Window → Move Window Tab to New Window 拆分；Merge All Windows 合并。⌘⇧W 关闭工作区，⌘W 关闭文件页。退出检查所有窗口的未保存内容并等待构建/扩展取消。关闭最后窗口后应用仍运行，开启 Remember Previous Workspace 时，点击 Dock 恢复最后关闭的工作区。

Finder、普通 `open` 和直接 CLI 重启会复用当前应用，已打开文件会定位所属工作区。`open -n` 请求另一个实例。旧版本或不同 bundle identity 的窗口要先正常保存退出，旧图标才消失。

## 功能与实现

Swift/AppKit 提供原生窗口、文本布局、标签、项目树、共享文档拆分、多选、撤销重做、字面/正则查找替换、文件生命周期及会话恢复。状态栏可选择编码/BOM、换行、语法、Tab/空格；支持暗色/浅色、字体和文件页/正文/项目行右键菜单。保存复核磁盘冲突并原子替换。构建命令和一次性 Python SDK 需明确选择；见 [扩展](plugins.zh-CN.md) 和 [配置例子](Resources/examples)。

Preferences → Editor Font 可选择系统等宽、Menlo、Monaco、Courier New 等已安装字体。View → Font 调整字号；配置 `font_face` 可指定其他已安装字体。偏好跨窗口共享并在重启后保留，不捆绑字体。原创图标在小尺寸简化网格/轨道，提高终端符号识别度。

Markdown 文件使用 Edit / Preview / Side by Side，⇧⌘V 切换预览，⌥⌘V 并排。Outline 在所有模式下一键显示完整预览，无二次菜单或 Build 步骤。预览与 HTML 导出直接显示正文，不插入 Contents；文档自身的锚点链接仍可导航。Markdown 的 ⌘B 和 Tools → Render Markdown 只渲染当前未保存内容，不执行命令或保存源文件。Export HTML… 导出含样式的页面。

打开/切换项目内文件时，自动展开祖先目录、选中并滚动定位，保持编辑焦点及其他目录展开状态。隐藏的侧栏保持隐藏，重新显示时跟随当前文件。未命名或项目外文件保留原项目。⇧⌘F 后台项目搜索；⌘/ 注释；⇧⌘D 复制行；⇧⌘K 删除行；⌥↑/⌥↓ 移动行。菜单和命令面板也提供入口。

## 作者与版本说明

Source Editor → About Source Editor 显示项目介绍、已安装版本、作者 `ziqi-wlb` 和邮箱 `550461053@qq.com`。介绍窗口支持 English/中文切换。Release Notes… 在原生窗口中离线显示版本历史，关闭所有编辑窗口后仍可访问。Contact Author… 或窗口中的联系按钮在系统邮件应用打开草稿，不会自动发送。

[中英文版本说明](RELEASE_NOTES.md) 由 `Resources/project-information.json` 生成，与应用共享同一信息来源。

## 草稿恢复

0.9.0+ 默认每 5 秒独立备份未保存文本。关闭窗口/退出时 Keep Drafts 补写最终状态，下次恢复文件和未命名笔记，不覆盖原件。Discard Drafts 和 File → Revert File… 明确恢复磁盘内容。写入失败或容量限制有可见通知；取消保留编辑能力。见 [草稿机制与验证](docs/draft-recovery.zh-CN.md)。原生撤销历史不跨进程保存。

## 验证、源码与限制

```sh
python3 tests/run_tests.py local-ui --ui --arch universal
python3 tests/check_portability.py
python3 tests/check_documentation.py
python3 scripts/export_source.py .build/SourceEditor-source.tar.gz --with-tests
```

发布应用只包含生产 Swift 和支持资源，不包含测试、截图、日志、个人路径或调查目录。源码包包含中英文说明、构建脚本和可选测试。性能及资源见 [性能导航](PERFORMANCE.zh-CN.md)，开发方式见 [开发指南](docs/development.zh-CN.md)。

基础词法规则并非完整 Sublime/TextMate 语法。LSP、完整片段、矩形选择、终端、Git 差异、公式/Mermaid/PDF、自动更新及签名公证尚不完整。原生 IME、VoiceOver、长期使用、多屏、物理 Intel 和 Windows GUI 仍需专项验收。Windows 功能较少；macOS 通过测试不代表 Windows 完成。参见 [功能与限制](docs/features.zh-CN.md)、[产品就绪](docs/product-readiness.zh-CN.md)。项目所有者尚未选择开源许可证。

Preferences → Remember Previous Workspace 默认开启，同时恢复文件夹与文件标签。关闭后重开进入空白窗口，保留可手动恢复的草稿与独立的最近文件夹历史。参见[工作区恢复](docs/workspace-restoration.zh-CN.md)。
