# 构建、贡献与验证

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

## Windows

Windows 10/11 x64：安装 Visual Studio Build Tools 的 Desktop development with C++ 和 Windows SDK，在 x64 开发者终端执行：

```powershell
# 从 editor/ 执行：
powershell -ExecutionPolicy Bypass -File windows/build.ps1
```

结果为 `windows/.build/SourceEditor.exe`，复制到所选目录运行。当前为便携版，无注册表安装器或文件关联。已安装 Zig 0.13.0 可按 [Windows 指南](../windows/README.md) 交叉编译；交叉编译不代表 Windows GUI 验证。

## 测试

```sh
# 从 editor/ 执行：
bash tests/run_all.sh local-check --arch universal
bash tests/run_all.sh local-ui --ui --arch universal
python3 tests/recovery_restart_test.py '.build/Source Editor Tests.app/Contents/MacOS/source-editor'
python3 tests/check_portability.py
```

原生 UI 测试需要登录中的 macOS 图形会话。`--ui` 增加原生菜单、sheet、文件页、预览、草稿退出与实际进程重启验证。release/test 分开构建，测试产物和 fixture 保存在忽略的 `.build/`，测试包不注册用户文档关联。

性能验证使用 [已有真实工作负载](../PERFORMANCE.md)，记录 elapsed/CPU/RSS/footprint、主队列 heartbeat 与对象生命周期。日志不能只用“RSS 未下降”证明泄漏，也不能把程序滚动调用时间当作 GPU 帧时间。新优化应与相同工作负载比较，说明冷/热状态、输入大小和未测范围。

## 源码与文档分发

```sh
python3 scripts/export_source.py .build/SourceEditor-source.tar.gz --with-tests
```

导出只包含应用源码、资源、构建脚本、测试和 `docs/`，不包含 `.build`、个人目录、二进制编辑器、调查输出或 Python 缓存。文档导航见 [docs/README](README.md)。完整仓库贡献约定在顶层 `CONTRIBUTING.md`；独立包的维护原则如下。

1. 文档对象拥有文本、磁盘身份和设置；UI 消费这些事实，不重复解释编码或修改状态。
2. 操作保持 Unicode 范围、文件冲突、撤销事务与选区；后台结果验证文档身份和修订。
3. 窗口/应用拥有对应任务与快照；关闭要等待自己的工作，取消与清理失败不能丢失所有权。
4. 修改 UI 运行相应真实原生回归并保存受影响窗口截图；Windows 修改需原生构建与执行，缺失验证须明确记录。
5. 更新功能矩阵、架构和相关使用文档；只报告执行过的检查。使用 Conventional Commit，不提交缓存、用户文件和机器特定路径。

GitHub Actions 已配置 macOS Universal 和 Windows MSVC 构建/编码检查；本地运行不等于云端 CI 已执行。仓库尚未选择 LICENSE，当前不能声称已经完成正式开源授权；维护者应确定许可证后将 LICENSE 纳入发行源码。
