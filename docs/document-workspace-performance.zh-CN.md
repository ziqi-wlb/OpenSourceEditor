# 文档工作区性能与资源

[English](document-workspace-performance.md)

本文对应 macOS **0.7.0** Markdown/搜索/恢复。更早文本引擎与包在 [优化](performance-optimization.zh-CN.md) 和 [包报告](package-and-memory.zh-CN.md)。0.7.0 以前无同等预览，不能作旧版预览 A/B。

## 所有权与避免的工作

普通编辑不创建 WKWebView。请求预览才创建视图/串行队列，回到 Edit 或关闭会取消并分离。worker 持文本快照而非文档/pane/撤销；修订/代次拒绝旧结果。

首次预览立即开始；连续编辑保留 250 ms 防抖。只移除明确请求的等待，没有减少 Foundation 解析、DOM 或 TextKit/WebKit 绘制。Foundation 解析不能中途打断。

Quick Open/项目搜索共用可取消遍历及覆盖总结。FileHandle 自身限额读取，不只检查文件元数据，避免增长文件突破内存边界。逐文件 autorelease pool 解码，只保留有限匹配。

恢复只捕获修改文档，每窗口一次写入，最终删除排在已有写入之后；JSON/磁盘在 utility 队列。保存移除旧快照文本，干净文件不复制。行命令仍为全文撤销事务，非新大文件引擎。

## 表示容量

| 工作 | 上限 |
| --- | --- |
| Markdown 输入 | 200 万 UTF-16 单位 |
| 块/样式 runs | 各 100,000 |
| 本地图片 | 单个4MiB、输入12MiB、4000万像素 |
| 嵌入图片输出 | 16MiB，含重复图片 |
| HTML 输出 | 32MiB，合并大块前检查 |
| 项目遍历 | 50,000 文件 |
| 项目搜索 | 单文件2MiB、总128MiB、2,000匹配 |
| 自动恢复 | 128修改文档、400万UTF-16 |
| 编码 session | 32 MiB |

图片缓存不豁免重复嵌入，base64 每次引用都计量。取消、容量与不可读范围明确报告，预览拒绝时源码保持可编辑。

## 分隔线与裁剪

旧分隔容器手动设置 pane frame，又继承 NSSplitView 的绘制/拖动状态，浅色截图出现额外竖线。现在一份几何负责布局、绘制、光标与命中，移除冲突的原生分隔表示。真实窗口鼠标拖动验证源码 pane 宽度变化。

macOS14 起 NSView 默认 clipsToBounds=false，旧版为 true。编辑/拆分/滚动容器明确裁剪自身范围，分隔绘制也裁剪。菜单/sheet 仍为独立窗口；深浅截图与拖动/生命周期一起验证。

## 测量口径

代表 Markdown 含中文/emoji、标题、任务、表格与围栏，每新进程六轮打开/预览、十次程序滚动、编辑/刷新和关闭。弱引用检查预览/文档销毁；原生 task 信息记录主进程 footprint/CPU。

WebKit XPC 的父进程为 launchd，单按 parent PID 会遗漏。诊断用唯一 identity 的复制测试包经 LaunchServices 启动，按系统 responsibility PID 归属 WebKit。可选符号只用于 Python 诊断，不链接应用；不可归属则明确范围不完整，不计其他应用。

每约0.1秒分别采主进程/族 RSS，族 RSS 会重复共享页，不等于唯一物理内存；最大值为采样峰值。Footprint/CPU 表仅主进程，WebKit CPU/唯一族内存未测。

首次含 WebKit 启动及待完成布局，暖值为第2–6轮中位数。文件/字体/系统缓存未清空。页面完成计时到 WebKit loaded，不含 WindowServer合成；编辑计时到新解析结果，含防抖。程序滚动非真实滚轮/GPU。测试与发行共享生产源码，但 fixture/计时只在测试包；发行空闲负载另测。

## 预览延迟

2026-10-24，M1 Pro/16 GiB、macOS14.2.1、Swift5.10，相同六轮和 fixture 摘要。v2 含首次250ms等待，v3/v4移除，v5加入分隔/裁剪修正。

| 版本 | 输入字节 | 首次页面ms | 暖页面中位数ms | 编辑中位数ms | 完整任务s | 主进程CPU s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 基线 v2 | 65,474 | 615.5 | 469.9 | 398.0 | 16.82 | 3.16 |
| 中间 v3 | 65,474 | 1,255.9 | 441.4 | 406.6 | 17.78 | 3.41 |
| 中间 v4 | 65,474 | 737.3 | 360.0 | 398.0 | 16.28 | 3.24 |
| 最终 v5 | 65,474 | 989.6 | 317.2 | 397.4 | 16.11 | 3.30 |
| 基线 v2 | 262,132 | 1,067.6 | 1,015.5 | 790.4 | 21.61 | 8.27 |
| 中间 v3 | 262,132 | 836.1 | 773.0 | 791.2 | 20.28 | 8.44 |
| 中间 v4 | 262,132 | 869.9 | 782.6 | 792.3 | 20.20 | 8.39 |
| 最终 v5 | 262,132 | 850.7 | 778.9 | 791.3 | 20.21 | 8.35 |

最终暖中位数较基线减少32.5%/23.3%，部分来自固定等待，也同时改分隔，调度/字体/WebKit变化不允许全归因单一改动。完整任务仅短4.2%/6.5%；编辑防抖不变，CPU未改善。小输入首次反而更慢，不声称冷启动加速；每项五个暖样本非全局分位数。

| 版本 | 输入 | 主进程峰值RSS MiB | 归属族峰值RSS MiB | heartbeat最大ms |
| --- | --- | ---: | ---: | ---: |
| 基线 v2 | 64 KiB | 128.19 | 230.77 | 263.4 |
| 中间 v3 | 64 KiB | 123.94 | 227.28 | 665.9 |
| 中间 v4 | 64 KiB | 138.77 | 241.89 | 404.9 |
| 最终 v5 | 64 KiB | 128.70 | 239.59 | 538.6 |
| 基线 v2 | 256 KiB | 152.05 | 337.45 | 155.2 |
| 中间 v3 | 256 KiB | 156.73 | 339.81 | 173.7 |
| 中间 v4 | 256 KiB | 165.94 | 348.75 | 172.2 |
| 最终 v5 | 256 KiB | 168.31 | 348.33 | 158.8 |

最多归属四进程：编辑器、WebContent、Networking、GPU。普通编辑无预览辅助进程。最终64KiB退出样本 responsibility PID=-1，标记不可归属，活跃样本可归属；族峰值只是已观察最大，不保证退出范围完整。v1未具应用responsibility，排除族比较。

Heartbeat含fixture/窗口/启动及渲染，64KiB最大在空窗口阶段出现，不能当作539ms输入停顿。两案都不证明sub100ms响应；仍需真实启动/输入/滚轮profile。后台解析未消除同步TextKit布局和WebKit创建。

## 关闭与保留对象

最终每轮预览关闭弱引用为零，六轮后文档也为零。关闭文档后的主进程footprint：

| 输入 | 第1–6轮 MiB | 窗口关闭后 MiB |
| --- | --- | ---: |
| 64 KiB | 83.97, 85.36, 82.61, 81.75, 80.11, 80.19 | 57.64 |
| 256 KiB | 79.25, 77.68, 77.14, 79.66, 95.82, 82.83 | 69.83 |

尾部无单调增长，但非长期或所有泄漏证明。分配器/字体/布局/图形可保留。96文档正常/撤销证据在 [旧报告](performance-optimization.zh-CN.md)。

## 同一发行程序空闲

复制相同Universal程序，隔离身份，一个1220×810窗口，普通CLI打开，无编辑/滚动/预览/测试代码。约5/15秒vmmap/ps采样会移动实际时间，三案窗口范围均验证。每案一次短空闲，非持续负载/分位数。

| 发行负载 | 最终采样s | 当前RSS MiB | 当前footprint MiB | 主进程累计CPU s |
| --- | ---: | ---: | ---: | ---: |
| 空窗口 | 15.56 | 36.98 | 25.0 | 0.17 |
| 单1MiB文件 | 15.61 | 82.16 | 60.5 | 0.51 |
| 八256KiB文件 | 15.67 | 62.69 | 74.8 | 1.34 |

Swift/中文/emoji fixture实际1,048,560字节，小文件262,140。两样本间空/八文件CPU在显示精度未变化，单文件+0.01s，只说明短空闲无明显持续CPU，不证明输入、泄漏或启用恢复/扩展无成本。

Footprint计费私有/压缩/图形；RSS驻留页可因压缩/回收下降而对象仍被持有。八文件RSS更低但footprint更高；不可相加或以RSS推断释放。预览表是不同测试程序/负载，不能替代发行空闲数据。

## Universal 包

| 产物 | 字节 | MiB |
| --- | ---: | ---: |
| Universal ZIP | 1,699,109 | 1.62 |
| 应用普通文件 | 3,621,148 | 3.45 |
| 分配文件块 | 3,653,632 | 3.48 |
| Universal程序 | 2,965,616 | 2.83 |
| ARM切片 | 1,474,672 | 1.41 |
| Intel切片 | 1,472,208 | 1.40 |
| 原创图标 | 632,482 | 0.60 |

ZIP程序与下方摘要一致。两切片只用系统框架/WebKit/ImageIO，无私有运行时。OS执行一个切片，Universal不使文本堆翻倍。目录/xattr/APFS共享不纳入文件块；相比0.6.1普通文件+25.5%、ZIP+17.6%，主要为原生功能。包小不代表预览内存小，WebKit辅助程序在系统外部。

## 证据与重跑

`product-070-final-v4`为450项通过/13合同跳过，独立源码包重建相同Universal字节。测量执行ARM；物理Intel、Windows、IME/VoiceOver、长期编辑及断电待验收。

发行程序摘要：

```text
2af7bc8a3f37eb839eb1108927a37aabf047dbc0b86c2ff9890808df77d59c33
```

最终性能测试程序：

```text
90a016f0fc580e2badaed655661e39572bc4da75e5f9f0d93c19437eff05d72c
```

生产源码合计（排序文件名+内容）：

```text
ccf9b1219b0d89de090137ad35b17d710158a7d86a74c22606e02f5e8438cc85
```

基线v2摘要 `abc4ec977fc95afc0abd9ee2954dbfe97e422c0450d044e33472b54a23281eb4`，v3/v4共用 `835cb6c0442f641e70e46084eabe3c4bffc924e30675b13ae53df45921e91def`。Manifest保留source/workload/fixture摘要；修改工作区身份不能只用提交前HEAD代替。

```sh
bash build.sh --arch universal
bash build.sh --tests
python3 tests/run_performance.py preview-local --no-build --cycles 6 \
  --cases markdown:65536 markdown:262144
python3 tests/measure_release_memory.py idle-local \
  --cases empty file multiple --duration 15
ditto -c -k --sequesterRsrc --keepParent '.build/Source Editor.app' \
  .build/SourceEditor-0.7.0-macos-universal.zip
python3 scripts/inspect_package.py '.build/Source Editor.app' \
  .build/diagnostics/package-local \
  --zip .build/SourceEditor-0.7.0-macos-universal.zip
```

证据：`.build/performance/markdown-070-v2`至`markdown-070-v5`、`.build/diagnostics/package-070-v4`、`release-070-idle-v2`、`.build/test-results/product-070-final-v4`。产物/个人路径/fixture/截图忽略，报告与脚本进入源码包。项目搜索/恢复有容量和功能测试，但未单独benchmark，不报告实测加速或低开销结论。
