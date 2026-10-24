# 0.9.0 资源与性能验证

测量源码对应提交 `84ebe43`（首次草稿实现），发行包摘要固定如下。后续样式缓存、矢量按钮与外部导入修正的测量见 [显示性能与界面完善](presentation-performance.md)，以下数据不能当作后续构建的包摘要或内存测量。

执行环境：Apple Silicon、macOS 14.2.1、Swift 5.10。数据来自真实本地进程；没有进行物理 Intel 或 Windows 原生性能测试。本报告记录草稿持久化、当前包大小和小规模文件工作负载，不能作为长期无泄漏或全面性能达标结论。

## 草稿写入

`RecoveryPerformanceTests` 在每个独立进程构造固定大小的文档，再测量实际 `EditorSession.Document` 捕获、后台 JSON 编码、原子磁盘写入到主队列完成回调。读取 JSON 验证发生在计时区间之后。没有创建 GUI 或子进程，文件系统缓存未清空；“首次”是新进程首次写入，“重复”是同进程第二次写入。

| UTF-16 内容量 | 首次耗时 | 重复耗时 | 首次 CPU | 重复 CPU | 重复写入后进程峰值 RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| 64 Ki 单位 | 7.20 ms | 2.72 ms | 4.49 ms | 2.51 ms | 11.25 MiB |
| 1 Mi 单位 | 56.39 ms | 34.21 ms | 36.42 ms | 33.69 ms | 22.94 MiB |
| 4 Mi 单位，上限 | 139.71 ms | 139.88 ms | 133.07 ms | 134.06 ms | 47.69 MiB |

RSS 是该新进程累计 high water，包含 fixture、文档、编码缓冲和验证读取；不是 GUI 应用总内存，也不是单次分配量。多字节编码的 JSON 字节大小与 UTF-16 单位不同。这些输入主要为 ASCII 加少量中文/emoji，不能代表所有 Unicode 内容或最坏 JSON 转义膨胀。

队列优化的原理是限制每个窗口一个实际写入和一个最新待写状态。重复计时请求合并，关闭时的最终快照替换尚未开始的周期请求；明确丢弃也排在正在进行的写入之后。这解决最后输入遗漏和清理后旧写入复活的问题。正常退出测试确认最新文本，而本测量没有做旧版同工作负载 A/B，因此不报告百分比加速。

## 发行包

0.9.0 Universal 发布程序包含 x86_64 和 arm64 两个实际编译切片。

| 内容 | 字节 | 大小 |
| --- | ---: | ---: |
| ZIP 下载包 | 1,988,488 | 1.90 MiB |
| 应用普通文件逻辑总量 | 4,356,789 | 4.15 MiB |
| 文件块分配总量 | 4,386,816 | 4.18 MiB |
| Universal Mach-O | 3,701,472 | 3.53 MiB |
| 多尺寸原创图标 | 632,266 | 617.45 KiB |

ZIP 内程序摘要与发布程序一致。发行程序 SHA-256 为 `6d718c6786ceb3a929f267442494a8b212de184e9d9300a16d17fa50f1597996`。普通文件统计不含目录、xattr、APFS 共享块；开发目录内历史应用、测试、日志和 fixture 不属于安装大小。

小尺寸图标移除细网格和轨道并加粗中心轮廓，提高 16/32 像素识别度；高分辨率图标保留科技风格。系统字体直接使用，不捆绑字体包。新增字体菜单改变显示配置，不修改文本/编码/缩进；回归验证字体偏好持久化。

## 发布程序运行内存

测量程序将相同发布 Mach-O 复制到独立 bundle identity，去掉文档关联，检查仅属于其 PID 的窗口和文件名。每个案例独立启动；5 秒等待后记录 RSS 与 vmmap footprint。没有编辑、预览或滚动，不触碰用户正在运行的应用。

| 场景 | RSS | Physical footprint | 进程累计 CPU |
| --- | ---: | ---: | ---: |
| 空窗口 | 40.83 MiB | 25.50 MiB | 0.19 s |
| 64 KiB 文件 | 75.42 MiB | 60.30 MiB | 0.34 s |

较早一次同版本 1 MiB 文件探针记录 RSS 80.52 MiB、footprint 65.40 MiB、CPU 0.54 s；它与随后更小输入来自不同启动，不能直接当作严格输入大小 A/B。RSS 和 footprint 含义不同；系统缓存、WindowServer 和文件系统缓存未归入应用自有内存。复制 bundle 会隔离偏好 identity；它没有自动加载用户的真实工作区数据。

## 文件打开、编辑、滚动与生命周期

`run_performance.py` 使用实际生产编辑路径和隔离的测试 bundle，每个场景一个新进程。1 MiB 工作负载打开、定位 EOF、编辑、撤销、程序滚动、关闭和重开；多文件场景完成两轮八个 256 KiB 文件的打开/切换/关闭。

| 场景 | 采样峰值 RSS | 最大主队列 heartbeat 延迟 | 结果 |
| --- | ---: | ---: | --- |
| 1 MiB 编辑/撤销/滚动/重开 | 109.30 MiB | 205.55 ms | 所有语义与清理检查通过 |
| 两轮共 16 文件打开/切换/关闭 | 121.27 MiB | 1,141.17 ms | 关闭后文档/storage/视图/layout 弱引用归零 |

1 MiB 文件 native open 返回 147.08 ms，到预设布局稳定检查约 575.41 ms；EOF 编辑 20.09 ms、撤销 14.43 ms。计时包含当前生产工作，不是文件系统冷启动。多文件场景仍连续执行同步打开/切换/关闭，约 1.14 秒的主队列停顿与早期报告同类问题一致，尚未优化掉。下一步需要异步文件读取与分阶段 UI 提交，并用同样工作负载验证语义与收益。

原生对象弱引用归零证明此路径没有继续持有这些对象，不能证明所有扩展/预览/长期交互都无内存泄漏。程序滚动不等于真实滚轮惯性、GPU 帧率或输入延迟；本轮也未重测 Markdown WebKit 进程族的峰值。

## 重跑与日志

```sh
# 从 editor/ 执行：
bash tests/run_all.sh draft-final --ui --arch universal
'.build/Source Editor Tests.app/Contents/MacOS/source-editor' --recovery-measure=1048576
python3 tests/measure_release_memory.py memory-run --duration 5 --cases empty file --bytes 65536
python3 tests/run_performance.py performance-run --no-build --cases file:1048576 multiple:262144 --cycles 2
python3 scripts/inspect_package.py '.build/Source Editor.app' .build/diagnostics/package-run --zip .build/SourceEditor-0.9.0-macos-universal.zip
```

原始证据：`.build/test-results/draft-final`、`.build/diagnostics/draft-090-write`、`.build/diagnostics/draft-090-package-zip`、`.build/diagnostics/draft-090-memory-final` 和 `.build/performance/draft-090-performance`。完整回归通过 **598 项检查，13 项明确跳过**，其中 23 项草稿/字体 UI 和 15 项真实正常退出/重启检查。各检查 elapsed 合计约 221 秒，具体记录在结果 JSON；agent token 未测量，不推断 token 或 CPU 全流程提升。
