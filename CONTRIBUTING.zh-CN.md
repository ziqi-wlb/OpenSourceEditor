# 贡献 OpenSourceEditor

[English](CONTRIBUTING.md)

请在 [OpenSourceEditor](https://github.com/ziqi-wlb/OpenSourceEditor) 提交 issue 或 pull request。问题报告包含应用版本、系统/架构、操作步骤、预期/实际行为，以及不含个人内容的最小样本；区分已经观察到的失败和未验证的解释。

## 开发

从仓库根目录构建，macOS/Windows 工具链和命令见 [开发指南](docs/development.zh-CN.md)。按修改范围运行检查：文档修改检查文档，编辑语义检查文档/核心，焦点、预览或布局检查受影响的原生 UI。跨模块和发布可使用 `--suite full`，说明实际执行的命令及尚未覆盖的范围。

文本、编码、路径、脏状态与撤销由文档拥有；应用操作前验证 UTF-16 选区以及后台结果的身份/版本。草稿与原文件分离，取消和写入失败保留用户内容。原生 GUI 必须在对应平台运行验证，Windows 也不例外。

本地应用调试时，正常退出并保留草稿，再更新安装。备份旧应用、安装验收包并核对版本/路径/摘要。仅修改 README 或构建脚本无需重编译或重启正在运行的编辑器。

## Pull request

- 说明具体问题、修改后的行为和已执行验证。
- 使用 Conventional Commit 标题，例如 `fix(editor): preserve selection` 或 `docs: clarify installation`。
- 同步更新相关中英文指南，使 `Resources/project-information.json` 的版本信息与 `Info.plist` 一致。
- 不提交生成应用、日志、测试截图、编译缓存、个人路径、凭据或第三方编辑器二进制。精选文档图片放在 `docs/images/`。
- 保留失败证据和限制，不把专项通过写成完整的平台验收。

性能工作应比较相同工作负载，说明冷/热状态、文件大小，以及相关的耗时、CPU 与内存；分配减少或某次 RSS 降低不等于编辑更快或没有泄漏。
