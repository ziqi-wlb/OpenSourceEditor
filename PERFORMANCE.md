# Performance and resource reports

The historical macOS 0.6.1 measurements below cover native Swift/AppKit, document-owned text caches and visible-region TextKit layout. Performance workloads run in isolated owned applications and retain their evidence under ignored `.build/` directories.

- [0.8.0 daily-use implementation, search optimization and resource measurements](docs/daily-use-implementation.md): bounded background search, ICU interruption, native undo fix, file-event handling and matched replacement benchmark.
- [Optimization principles, before/after results and remaining costs](docs/performance-optimization.md): file opening, caret movement, native edits/undo, syntax painting, scrolling and 96-file lifetime checks.
- [Release package size and runtime memory](docs/package-and-memory.md): compressed versus installed size, Intel/ARM slices, native dependencies, release idle/file memory and cache retention.

On the measured 4 MiB source workload, native open decreased from 14.52 s to 0.374 s and open-settled physical footprint from 113.64 to 61.96 MiB. First visits to unlaid text still pay layout costs. Measurements are individual completed macOS runs; Windows runtime, physical Intel GUI and real trackpad/GPU frame latency remain unmeasured.

For the optional GUI benchmarks, use a checkout or source package containing tests:

```sh
python3 tests/run_performance.py local-performance
```

The child reports explain the workload, evidence, reproduction commands and limitations. Benchmarks and diagnostics are excluded from the release executable.
