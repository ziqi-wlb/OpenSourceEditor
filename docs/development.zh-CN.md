# 构建、贡献与验证

[English](development.md)

应用源码从 `editor/` 可独立编译。安装或运行不依赖逆向调查数据、用户机器的个人路径或本项目之外的工具工作区。

## macOS

要求 macOS 13+ 和 Xcode Command Line Tools。在系统工具缺失时由开发者运行 `xcode-select --install`；构建脚本不会安装或升级工具链。Python 3 只用于扩展与部分测试/报告。

从 `editor/` 执行：

```sh
bash build.sh --arch universal  # 同时编译 Intel x86_64 与 ARM64
open '.build/Source Editor.app'
bash scripts/install_macos.sh universal
bash package.sh universal
```

可用 `--arch arm64` 或 `--arch x86_64` 构建单架构。Universal 包含两份实际编译切片，不是模拟架构支持；另一架构的原生 GUI 应在对应硬件验证。安装器检查是否有运行实例，保存旧安装，安装到 `~/Applications/Source Editor.app`，注册 Launch Services 后启动。Finder 的 Open With 提供 Markdown 与文本文件关联，安装不会自动更改默认编辑器。

程序目前没有开发者签名或公证。下载后的系统确认按正常 Finder Open 流程处理；脚本不关闭系统安全设置。

## 本地调试交付

每轮编辑器调试或功能修改完成后，都要本地安装并验证启动。编译或测试通过不会更新已经运行的安装副本，不能用旧版界面判断修改效果。

1. 编译并执行与修改相关的检查，保留验收通过的程序和对应摘要。
2. 正常退出已安装应用。未完成的编辑选择 Keep Drafts，保留原文件，并等待应用拥有的任务结束。更新不能强制退出或丢弃内容。
3. 备份旧安装，安装已验收的程序，注册 Launch Services，再启动安装目录中的副本。安装器拒绝覆盖运行中的应用。
4. 核对已安装版本、实际运行的应用路径及程序摘要与验收产物一致，确认只有一个正式实例；将证据保存在对应的 `.build/test-results/` 下，再报告修复完成。

常规本地安装和正常重启属于已授权的开发流程。若保存对话框等需要用户决定才能安全退出，应保留已验收的程序，明确说明剩余步骤。

## Windows

Windows 10/11 x64：安装 Visual Studio Build Tools 的 Desktop development with C++ 和 Windows SDK，在 x64 开发者终端执行：

```powershell
# 从 editor/ 执行：
powershell -ExecutionPolicy Bypass -File windows/build.ps1
```

结果为 `windows/.build/SourceEditor.exe`，复制到所选目录运行。当前为便携版，无注册表安装器或文件关联。已安装 Zig 0.13.0 可按 [Windows 指南](../windows/README.zh-CN.md) 交叉编译；交叉编译不代表 Windows GUI 验证。

## 测试

```sh
# 从 editor/ 执行：
bash tests/run_all.sh local-check --arch universal
bash tests/run_all.sh local-ui --ui --arch universal
python3 tests/recovery_restart_test.py '.build/Source Editor Tests.app/Contents/MacOS/source-editor'
python3 tests/workspace_restart_test.py '.build/Source Editor Tests.app/Contents/MacOS/source-editor'
python3 tests/check_portability.py
python3 tests/check_documentation.py
python3 tests/run_tests.py file-location-097 --ui --arch universal
python3 scripts/generate_release_notes.py --check
```

原生 UI 测试需要登录中的 macOS 图形会话。`--ui` 增加原生菜单、sheet、文件页、预览、草稿退出与实际进程重启验证。release/test 分开构建，测试产物和 fixture 保存在忽略的 `.build/`，测试包不注册用户文档关联。

性能验证使用 [已有真实工作负载](../PERFORMANCE.zh-CN.md)，记录 elapsed/CPU/RSS/footprint、主队列 heartbeat 与对象生命周期。日志不能只用“RSS 未下降”证明泄漏，也不能把程序滚动调用时间当作 GPU 帧时间。新优化应与相同工作负载比较，说明冷/热状态、输入大小和未测范围。

## 源码与文档分发

所有公开应用指南提供英文 `.md` 和中文 `.zh-CN.md`，文档开头相互链接，两份均进入源码包。`Resources/project-information.json` 拥有作者和版本历史；修改后运行 `python3 scripts/generate_release_notes.py`，再检查生成文档和 `Info.plist` 版本一致性。

```sh
python3 scripts/export_source.py .build/SourceEditor-source.tar.gz --with-tests
```

导出只包含应用源码、资源、构建脚本、测试和 `docs/`，不包含 `.build`、个人目录、二进制编辑器、调查输出或 Python 缓存。文档导航见 [docs/README](README.zh-CN.md)。完整仓库贡献约定在顶层 `CONTRIBUTING.md`；独立包的维护原则如下。

1. 文档对象拥有文本、磁盘身份和设置；UI 消费这些事实，不重复解释编码或修改状态。
2. 操作保持 Unicode 范围、文件冲突、撤销事务与选区；后台结果验证文档身份和修订。
3. 窗口/应用拥有对应任务与快照；关闭要等待自己的工作，取消与清理失败不能丢失所有权。
4. 修改 UI 运行相应真实原生回归并保存受影响窗口截图；Windows 修改需原生构建与执行，缺失验证须明确记录。
5. 更新功能矩阵、架构和相关使用文档；只报告执行过的检查。使用 Conventional Commit，不提交缓存、用户文件和机器特定路径。

GitHub Actions 已配置 macOS Universal 和 Windows MSVC 构建/编码检查；本地运行不等于云端 CI 已执行。仓库尚未选择 LICENSE，当前不能声称已经完成正式开源授权；维护者应确定许可证后将 LICENSE 纳入发行源码。

Preferences → Remember Previous Workspace 默认开启，同时恢复文件夹与文件标签。关闭后重开进入空白窗口，保留可手动恢复的草稿与独立的最近文件夹历史。参见[工作区恢复](workspace-restoration.zh-CN.md)。

新窗口和纯文件夹项目显示带快捷操作与最近记录的原生主页，关闭最后一个文件标签后回到主页。通过项目标题/窗口标题栏的侧栏图标或 ⌃⌘B 扩大主区域。参见[工作区主页](workspace-home.zh-CN.md)。

macOS 0.9.6 支持左右/上下编辑区切分，各区域独立选择文件并保留光标、滚动位置。通过标题栏图标或 ⌥⌘2 切分、⌥⌘3 切换区域、⌥⌘1 保留活动区域并合并；工作区/会话恢复保留区域状态。参见[编辑区切分](editor-splits.zh-CN.md)。

macOS 0.9.7 增加编辑区上方的文件输入栏：支持完整名称、显式路径、重名选择及活动区域路由。⌥⌘O 聚焦，回车打开，Escape 取消。参见[文件输入栏](file-location.zh-CN.md)。原生检查覆盖输入栏、预览、主页、切分和专注模式；结果属于当前验收运行，不沿用旧切分版本的验收结果。
