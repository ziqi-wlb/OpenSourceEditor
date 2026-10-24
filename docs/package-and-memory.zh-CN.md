# 软件包大小与运行内存

[English](package-and-memory.md)

0.9.1 见 [显示性能](presentation-performance.zh-CN.md)，0.9.0 见 [草稿资源](release-090-performance.zh-CN.md)，0.7.0 见 [Markdown 资源](document-workspace-performance.zh-CN.md)。下方是历史 **0.6.1**，2026-10-24 测于 M1 Pro/16 GiB、macOS 14.2.1、Swift 5.10。1 MiB=1,048,576 字节，测量自有编辑器而非 Sublime。

## 安装清单

| 产物 | 字节 | 大小 | 口径 |
| --- | ---: | ---: | --- |
| macOS Universal ZIP | 1,445,426 | 1.38 MiB | 下载大小，含归档元数据 |
| 安装普通文件 | 2,885,029 | 2.75 MiB | 未压缩普通文件长度合计 |
| 分配文件块 | 2,916,352 | 2.78 MiB | 此文件系统 st_blocks×512 |
| Universal 程序 | 2,230,480 | 2.13 MiB | 两切片与对齐 |
| ARM 切片 | 1,099,984 | 1.05 MiB | lipo 切片大小 |
| Intel 切片 | 1,112,624 | 1.06 MiB | lipo 切片大小 |
| 应用图标 | 632,482 | 617.66 KiB | 原创多尺寸 ICNS |
| Python SDK/宿主例子 | 20,195 | 19.72 KiB | 四个 Python 文件，不捆绑解释器 |
| 配置与 plist | 1,872 | 1.83 KiB | 三个 JSON 与应用元数据 |

可执行文件占安装字节 77.31%，图标 21.92%。ZIP 中程序压缩到 805,697 字节，已压缩图标仍为 623,350，占 ZIP 约 43%。源码报告、测试、基准、编译缓存、数据、截图及调查资料不进入应用。

分配块不包含目录/xattr；APFS 克隆、共享、压缩或其他文件系统改变实际增量。开发 `.build/` 含多版本和 fixture，不能当作安装大小。

程序及 ZIP 内程序 SHA-256 一致：

```text
28eccc1fe508df95dbf05f574b49bd68eadf3e29f06993257e349515208ca006
```

`otool -L` 两切片只链接系统 AppKit/Foundation/CoreGraphics/CryptoKit/Objective-C/Swift 库，无私有运行时、Electron/Chromium/Node。用户执行扩展时可启动外部 Python；本次空闲负载无构建/扩展。

ARM `__TEXT`/`__LINKEDIT` 为 655,360/393,216 字节，Intel 679,936/372,736；这是映射范围，含对齐/零填充，不是堆或文件总量。4 GiB `__PAGEZERO` 只保留不可访问地址，不分配 4 GiB。没有 `__DWARF`。系统运行一个切片，Universal 不使堆翻倍。

独立实验 Windows 0.5.0 x64 EXE 470,016 字节/459 KiB，ZIP 193,426/189 KiB，匹配 EXE+README，不含 4,263,936 字节 PDB。功能更少；Windows 原生运行、内存及 MSVC 包大小未测，这些是交叉编译产物。

## 发行程序运行测量

复制发行应用并更换诊断 identity，Mach-O 摘要不变。直接启动自有 GUI，隔离偏好/最近文件；正常 CLI 打开生成文件，不含测试代码。fixture 在外部 Python 中，不由编辑器测试入口持有。

每案新进程，一个 1220×810 默认窗口，不编辑/滚动。约 5/15/30 秒采样，空窗口到 60 秒。CoreGraphics 检查自有身份、窗口和文件名；所有报告案例标题可见且通过。vmmap 提供 footprint/峰值，ps 提供 RSS/累计 CPU。采样耗时使时间偏移约 0.6–2 s。只停止自有进程，清理自有偏好和窗口状态；失败记录在 manifest。

| 发行负载 | 最终采样 | 当前 RSS | 当前 footprint | footprint 高水位 | 累计 CPU |
| --- | ---: | ---: | ---: | ---: | ---: |
| 空窗口 | 60.61 s | 39.38 MiB | 30.4 MiB | 45.5 MiB | 0.24 s |
| 单个 1 MiB 文件 | 30.61 s | 51.73 MiB | 63.2 MiB | 91.5 MiB | 0.53 s |
| 八个 256 KiB 文件 | 30.59 s | 73.59 MiB | 74.7 MiB | 100.5 MiB | 1.33 s |
| 单个 4 MiB 文件 | 30.60 s | 65.36 MiB | 74.2 MiB | 109.1 MiB | 0.63 s |

空进程 footprint 暖启动 23.7→34.3 MiB，最终 30.4；首末 CPU 只增加约 0.04 s，区间平均约 0.08% 单核。单文件增加 0.01–0.02 s，八文件保持 1.33 s。只是短期低空闲 CPU，不证明编辑响应或长期内存稳定。

fixture 含 Swift/中文/emoji，实际 1,048,560/4,194,291 字节，小文件各 262,140；1 MiB 为 925,200 UTF-16，4 MiB 为 3,700,845。词法上限 2,000,000，所以 4 MiB 纯文本显示，不能按高亮 1 MiB 四倍推导。未清文件缓存/固定系统内存压力，每行一次完成运行而非分位数。

## 内存口径

RSS 是 ps 当前驻留页；footprint 是 macOS task ledger 的私有/脏、压缩和图形等收费内存，不可互换或相加。页压缩/回收时进程可能仍拥有数据，RSS 降低不表示文档释放。vmmap SWAPPED 不独立证明磁盘换页。

vmmap 包含共享系统库。空进程虚拟映射约 3 GiB，区域表驻留 229.1 MiB，但 RSS 39.38、footprint 30.4。汇总映射会把系统共享内存重复归给应用。malloc 地址预留约 1.4 GiB，实际最终分配只有 9.8 MiB。

| 最终 vmmap 类别 | 空窗口 | 1 MiB 文件 | 八文件 | 4 MiB 文件 |
| --- | ---: | ---: | ---: | ---: |
| Malloc 实际分配 | 9.8 MiB | 17.2 MiB | 27.3 MiB | 29.7 MiB |
| IOSurface 虚拟分配 | 4.67 MiB | 23.4 MiB | 23.4 MiB | 23.4 MiB |
| IOSurface 驻留页 | 3.23 MiB | 23.3 MiB | 23.3 MiB | 23.3 MiB |

这些 allocator/区域类别不是 footprint 的完整可加分区。Malloc 含应用和框架；IOSurface/CoreAnimation/IOAccelerator 是原生绘图。WindowServer 不纳入，因此不能按文件字节常数估算总内存。

每个文档持 attributed storage、已保存文本基线、撤销与懒 offset 缓存。打开时读/解码/hash 原始字节，不长期缓存完整磁盘 Data。桥接、编码和写时复制决定物理拷贝成本，不能假设固定共享比例。拆分共享文本事实，但每 pane 有布局/视图。行缓存随行数、词法缓存随匹配增长；编辑失效，全文撤销可能持旧文本。滚动可保留字形/图形分配。

## 关闭与泄漏

独立 AppKit 测试各跑十二轮八文件，即每进程 96 个不同文档，普通/撤销分开。每轮关闭 document/storage/view/layout 弱引用为零，非活动文档无 layout。普通第7–12轮 footprint 82.22–92.92，最后82.22、窗口关闭67.75 MiB；撤销尾部64.11–68.82，无持续增长。

这是含 fixture/编辑/滚动的测试程序，不能替换发行空闲数据。跟踪对象已销毁不等于全堆检查；分配池、字体、TextKit、图形可能仍热。单独保留 RSS 不能证明文档泄漏。详见 [优化](performance-optimization.zh-CN.md)。

## 证据和重跑

从编辑器目录，在发行构建后使用新输出名称：

```sh
bash package.sh universal
python3 scripts/inspect_package.py '.build/Source Editor.app' \
  .build/diagnostics/package-local --zip .build/SourceEditor-0.6.1-macos-universal.zip
# Requires a logged-in macOS GUI session and a checkout/source package with tests:
python3 tests/measure_release_memory.py idle-local --cases empty --duration 60
python3 tests/measure_release_memory.py files-local --cases file multiple --duration 30
python3 tests/measure_release_memory.py large-local --cases file --bytes 4194304 --duration 30
python3 tests/run_performance.py lifecycle-local --cycles 12 --cases multiple:262144 undo:262144
```

`.build/diagnostics/resources-061-package/` 保存 inventory、切片、依赖、Mach-O 和 Windows ZIP 清单；同父目录 resources-061-empty/files/four-mib 保存运行 manifest/vmmap。优化/lifetime 在 `.build/performance/final/`、`lifetime-final/`。二进制/诊断忽略，报告/脚本进入源码包；运行驱动需要带测试包。

没有可删除的第三方运行时。单架构可少约 1.05 MiB 未压缩文件，Universal 服务两架构。图标压缩/分辨率变化需视觉验收；符号剥离、rope/piece-table 尚未实现或测量。已知剩余成本为同步解码/全文编辑缓存撤销、新区域布局、图形缓存及明确启动的扩展/构建。Windows、物理 Intel、滚轮/IME、更大文件和长期工作待测。
