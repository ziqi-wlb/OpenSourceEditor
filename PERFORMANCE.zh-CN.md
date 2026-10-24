# 性能与资源报告

[English](PERFORMANCE.md)

历史 macOS 0.6.1 测量覆盖 Swift/AppKit、文档拥有的文本缓存和可见范围 TextKit 布局。性能工作负载使用隔离应用，证据保存在忽略的 `.build/` 中。

- [0.9.1 显示与多文件性能](docs/presentation-performance.zh-CN.md)：共享样式、当前标签复用、相同原生工作负载 A/B 与界面完善。
- [0.9.0 草稿与资源](docs/release-090-performance.zh-CN.md)：后台备份写入、包大小、文件工作负载与运行内存。
- [0.8.0 日常使用与搜索优化](docs/daily-use-implementation.zh-CN.md)：限额后台搜索、ICU 中断、撤销修正、文件事件与替换基准。
- [优化原理与效果](docs/performance-optimization.zh-CN.md)：打开、定位、编辑/撤销、高亮、滚动及 96 文件生命周期。
- [包大小与运行内存](docs/package-and-memory.zh-CN.md)：压缩/安装大小、Intel/ARM 切片、系统依赖、RSS/footprint 与缓存。
- [Markdown/WebKit 资源](docs/document-workspace-performance.zh-CN.md)：预览延迟、辅助进程归属和容量限制。

已测 4 MiB 工作负载的原生打开从 14.52 s 降为 0.374 s，布局稳定后的 footprint 从 113.64 降为 61.96 MiB。首次访问未布局文字仍有开销。单次 macOS 完成任务不代表全局分位数；Windows、物理 Intel、真实触控板/GPU 帧延迟未测。

```sh
python3 tests/run_performance.py local-performance
```

需要包含测试的源码包和 macOS 图形会话。子报告说明工作负载、证据、重跑与限制；基准和诊断入口不进入发行程序。
