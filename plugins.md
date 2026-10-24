# 自有 Python 扩展宿主

`Resources/plugin_host/` 是独立编写的 stdlib-only SDK，不加载 Sublime 出厂 Python 文件，不依赖原产品进程、授权或 IPC。它对一个输入快照执行一个明确选定的本地插件命令，然后退出；没有自动插件扫描、常驻 worker、原生事件监听或完整 Sublime Python API 兼容声明。

插件是本机当前用户权限下的 Python 文件。显式选择插件并调用命令会执行该文件的顶层代码和命令体；`-I` 隔离 Python 环境搜索路径，不是插件沙箱。该执行边界供自有编辑器扩展使用。

## 输入和输出

调用形式：

```text
/usr/bin/python3 -I /ABS/Resources/plugin_host/host.py /ABS/plugin.py COMMAND
```

stdin 是一份 UTF-8 JSON：

```json
{"text":"a😀b","selections":[[0,4]],"args":{},"settings":{}}
```

`text`、`selections` 必填；`args`、`settings` 为可选 object，默认 `{}`。选区使用 Swift `NSRange` 的 `[location,length]`，不是 `[a,b]`，单位为 UTF16。拒绝多余顶层字段、负值/bool offset、越界范围、不成对 surrogate、切开 emoji surrogate pair、非 JSON 的 NaN/Infinity。CLI 允许最后追加 `ARGS_JSON`；它显式替代 stdin 的 args。

成功时 stdout 仅一行 JSON：

```json
{"ok":true,"text":"b😀a","selections":[[0,4]],"status":"Reversed local selections"}
```

失败时 stdout 也是一行 JSON：

```json
{"ok":false,"error":{"type":"RuntimeError","message":"..."},"text":"原始文本","selections":[[0,4]]}
```

如果输入尚未有效解析，失败结果可以省略 text/selections。有效输入的插件失败返回原快照，部分文本修改不会提交；插件对外部文件等产生的副作用不在快照回滚范围内。普通 import/run `print` 输出重定向至 stderr。协议级成功和逻辑失败均正常退出 `0`；父进程必须检查 `ok`，并分别处理启动失败、超时、signal 和输出限制，不能仅靠退出码提交编辑。错误消息最多 4096 个字符。

JSON 输入和成功结果各限制 8 MiB，文本限制 4 Mi UTF16 units，输入选择最多 100000 个。父进程需要独立限制时间和 stdout/stderr，宿主没有常驻线程或 delayed callback。自有 UI 还应比较命令启动前后的文档状态，只有状态仍匹配才把成功结果提交为一次 undo 操作。

## SDK 的明确范围

`sublime.py` 提供 Region、Selection、Settings、View、Window、Edit，以及 status_message、active_window、set_timeout(callback,0)。Region 的 a/b 保留方向；输出 NSRange 会归一化方向。View 的 size、substr、insert、erase、replace、word、line、full_line 和 sel 全部使用 UTF16。UTF16→Python index 映射用缓存的紧凑 array，在文本变化时失效。

Selection 采用快照迭代。相交区与落在范围上的光标会合并；仅端点接触的两个非空区域保留分离。合并保留排序后第一段的方向。通用 replace 把区内点移动到新文本末端，但非空范围起点保留原位置，后方点按长度差移动；insert builtin 完成后把其操作选区折叠为插入末端光标。这些是 SDK 自有、可测的规则，原生 Sublime 的选择合并/移动仍是未知项。

word 使用 Python Unicode `\w+`；line 处理 LF/CRLF 并排除行终止符，full_line 包含行终止符。选区恰好结束于下一行起点时，行范围排除那条未选中的下一行。没有宣称这些规则与原生 word boundary、文本 Point 或 IME 完全一致。

`View.run_command` 和 `Window.run_command` 只允许四个明确 builtin：append、insert、upper_case、lower_case。文字通过 `characters` 参数传入；大小写只使用自有宿主 Python 字符串方法。其余命令（包括 undo、redo、build、原生 UI 命令）返回 NotImplementedError；不会转发给安装的 Sublime。Settings 仅保存本次快照内的值，不写配置文件，也不返回持久化配置。

`sublime_plugin.py` 提供 Command、TextCommand、WindowCommand、ApplicationCommand。host 只注册选定插件模块本身定义的命令类；同一类的别名去重，同名不同命令明确失败。Command.name 按已读取的命名行为独立实现：SortLinesCommand→sort_lines；HTTPServerCommand→h_tTPServer。默认不传 event；enable hook 可接受命令 args 或无参数，并且必须返回 bool。

每次命令使用一个 edit scope。TextCommand.run 收到 `edit`；WindowCommand/ApplicationCommand 可访问当前快照窗口。退出 scope 后 token 失效，其他 View 或伪造 Edit 不能修改文本。host 失败时返回原快照；native 的 begin/end edit、异常回滚、undo grouping 和真正窗口路由未据此确认。

SDK 先加载自身 sublime/sublime_plugin，再仅增加显式插件的父目录供同目录辅助模块导入；调用目录和 Python 环境由 `-I` 排除。不会读取用户 Packages、自动调用 plugin_loaded/unloaded、延迟异步 callback 或导入原产品代码。插件主动更改 import/sys.stdout 等全局状态超出普通 print 隔离合同。

## 示例与验证

demo_plugin.py 定义两个自有命令：reverse_selection 反转选中文本的 Unicode codepoint 序列；prefix_selection 在各选区前插入 args.prefix。反转保持 surrogate pair，但不承诺组合字符或 emoji grapheme cluster 保持一个视觉单元。

```text
python3 tests/plugin_host_test.py
```

17 个测试中，16 个通过真实独立 CLI 子进程检验公开输入/输出；另一个直接验证 SDK edit scope 成功/异常退出后的 token 失效。覆盖 UTF16 emoji、多选、Region 方向、CRLF/word、普通 stdout 污染隔离、失败快照回滚、Edit 归属、同步 callback/settings、无参数 enable hook、禁用命令、args 覆盖、SDK 模块搜索优先级、严格输入与显式 unsupported undo/async。测试只运行自有插件，不构成原生 Sublime 运行兼容或性能测量。

当前完整原产品 Python API、resident worker/native IPC、事件/UI/async、项目与构建宿主、插件之间共享状态均未支持。编辑历史归自有 Swift UI；一次性 Python worker 不保存 undo/redo 栈。
