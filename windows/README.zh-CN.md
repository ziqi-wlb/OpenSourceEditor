# Windows 原生编辑器（实验实现）

[English](README.md)

使用 C++17、Win32 和系统 RichEdit，x64 EXE 不依赖 Python、Node 或第三方 GUI 框架。目标为 Windows 10/11，原生 GUI 运行仍需验证。

## 编译和安装

安装 Visual Studio Build Tools 的“使用 C++ 的桌面开发”及 Windows SDK。在 x64 Native Tools Command Prompt 中进入仓库：

```powershell
powershell -ExecutionPolicy Bypass -File windows/build.ps1
```

生成 `windows/.build/SourceEditor.exe`，复制到任意目录运行。当前为便携程序，无注册表安装器、文件关联或后台服务。EXE 未签名，系统可能要求正常确认。

已安装 Zig 0.13.0 时可交叉编译：

```sh
ZIG_BIN=/path/to/zig bash windows/build.sh
```

脚本不会下载编译器。GitHub Actions 配置了 Windows/MSVC 构建；PE 文件和导入正确只证明编译，实际 Windows GUI 验收另行记录。

## 能力与限制

支持 Unicode 文本、文件页、懒加载目录树、字面前向搜索/F3、保存/另存为/全部保存、磁盘冲突保护和原子替换；编码为 UTF-8、UTF-8 BOM、UTF-16 LE BOM；LF/CRLF、Tab/空格宽度与深浅正文主题。

文件页右键可复制完整/相对路径与名称、Explorer 定位、保存、关闭其他/右侧文件页；正文和项目行也有右键菜单。状态栏右键选择编码、换行及缩进。

尚无 macOS 多光标、正则替换、拆分、会话恢复、语法高亮、Python 扩展、项目介绍窗口或完整设置。切换文件页会重置撤销历史。稳定发行前需原生验收 RichEdit/Win32、长路径、IME、高 DPI、剪贴板和文件对话框。
