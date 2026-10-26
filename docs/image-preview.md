# Image preview

[中文](image-preview.zh-CN.md)

Open an image through **File → Open**, the project sidebar, Quick Open, the clickable window title, Finder's **Open With**, or a CLI file argument. It becomes a read-only file tab. Images and text can occupy different split panes; selecting an image updates the title, sidebar selection and file context actions.

The toolbar provides **Fit**, **100%**, **−**, **+** and **Reload**. Fit shows the image inside the available pane without enlarging small images. 100% uses source-pixel dimensions in AppKit points. `+`/`−`, `0` (fit), `1` (source size) and pinch gestures work while the preview has focus. Standard scrollbars and scrolling navigate enlarged images. **View → Image Preview** offers the same actions. The checkerboard shows transparent areas; dimensions, file size and multi-frame status appear beside the controls. Right-click an image or its file tab for path copying, folder/sidebar reveal, close and split actions; the image area also offers zoom/reload actions.

PNG, JPEG/JPG/JPE, GIF, BMP, TIFF, HEIC/HEIF, WebP and ICO extensions are routed to macOS ImageIO. Decoder availability depends on the operating system. Multi-frame GIF/TIFF/ICO files display the **first frame/page only**; animation and page switching are not implemented. SVG remains editable source; PDF, audio and video previews are not part of this implementation. There are no remote preview requests or new third-party dependencies.

Images are read-only. Save, Save As, text search, encoding and indentation operations are unavailable for image tabs; the core also rejects text saves so binary files cannot be replaced with an empty buffer. Use an image editor to modify the original. Reload and file-system events update the preview. Workspace restoration and Save Session retain image file references rather than image bytes; missing image references report an error. Images create no unsaved text drafts. A restored or newly selected image starts in Fit mode; zoom is local to its current visible pane.

`EditorDocument` owns the file type and `EditorImageAsset` metadata. Image bytes never enter `NSTextStorage` or text decoding. `EditorPane` presents `ImagePreviewView` for image documents and the existing TextKit view for text documents; active-pane routing remains owned by `EditorWorkspace`. Optional image flags in desktop/session records preserve compatibility with old text records, including image files renamed to another extension.

ImageIO thumbnail decoding runs on a shared queue with **two concurrent operations**. A visible pane retains a raster of at most **2048 pixels on its longest edge**, approximately **16 MiB of RGBA pixels** at the square maximum. Tabs retain only file metadata when no longer displayed, and cancelled/closed views reject late results. Large-source 100% zoom enlarges the bounded preview; it does not decode full-resolution detail. The toolbar labels this reduced-resolution case. Inputs are limited to **128 MiB**, **64 million source pixels**, and **100,000 pixels per dimension**. These constrain supported workloads; decoder workspaces and compositor memory can exceed the retained raster size, and this bound is not a process RSS measurement.

Native checks generate their image fixtures under ignored `.build/`, exercising PNG/JPEG/GIF/BMP/TIFF, EXIF rotation, bounded decoding, source preservation, native controls/context menus, light/dark layouts, mixed panes, real file events, closed-view release and rapid open/close cycles. Separate processes verify workspace and explicit-session restoration. HEIC/WebP/ICO decoder behavior, actual trackpad gestures, physical Intel GUI and Windows parity need separate validation. See [development](development.md) for reproducible checks and the repository validation record for executed results.

## Local resource measurements

The 0.9.9 Universal executable is **4,582,080 bytes**; files inside the application total **5.01 MiB** (neither allocated disk space nor compressed package size). The same accepted release executable ran in copied bundles with separate application identities, opening 0, 1 and 16 image tabs with one visible pane. The workload is a resized synthetic transparent PNG, 4096 × 2048 pixels. Each separate process ran for about five seconds, sampling `ps` RSS and cumulative CPU time every 250 ms; `vmmap` summaries and native window screenshots were retained.

| Image tabs / 图片标签 | Last sampled RSS (MiB) / 末次 RSS | Sampled peak RSS (MiB) / 采样峰值 | CPU time / CPU 时间 |
| --- | --- | --- | --- |
| 0 | 49.6 | 60.7 | 0:00.20 |
| 1 | 69.4 | 69.4 | 0:00.27 |
| 16 | 99.7 | 315.2 | 0:02.27 |

These short local samples include application, decoder and UI memory and depend on OS caching, compression and competing host load. Sampled peaks are not complete instantaneous peaks and exclude the separate WindowServer process. No equivalent previous image preview exists for a before/after comparison; these are neither speedup claims nor proof of long-term leak freedom. Native checks separately verify closed-view release and 16 rapid open/close cycles. First-open latency, large real photographs, sustained scrolling, long-run cycles and multiple-visible-pane RSS were not measured.

Local evidence is under `.build/test-results/image-preview-099-accepted/resources/`. To remeasure, use an independent application identity to isolate personal workspaces, collect `ps -p <pid> -o rss= -o time=` and `vmmap -summary <pid>`, and verify the native window displays the intended image.
