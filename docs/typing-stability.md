# Return, scrolling and text colors

[中文](typing-stability.zh-CN.md)

0.9.10 fixes viewport jumps when pressing Return in a Markdown numbered list. Return continues the list, places the caret on the new line and keeps the editing location visible. Tab, plain-text/code Return and undo/redo of custom edits share the same cursor transaction; other split views retain their own cursors and scrolling.

Previously, a command produced complete text and `EditorDocument` replaced the entire `NSTextStorage`, even for one newline. TextKit lost layout for unchanged content and could shrink or move the viewport. The document owner now finds the changed span using equal UTF-16 prefixes/suffixes and replaces that span only. Boundaries avoid splitting surrogate pairs, preserving unchanged attributes and layout. The native cursor transaction then reveals the primary caret. Reading a new file and explicit reload can still replace the complete document.

Commands still produce complete results, and undo still retains text snapshots. This is not a constant-cost command or undo-memory claim; it removes whole-file TextKit invalidation and overwriting of unchanged attributes.

Retained undo and checkpoint text now explicitly copy the storage's UTF-16 characters into an owned Swift string. This gives those snapshots a stable lifetime during in-place edits. Diagnostic before/after text uses the same document boundary, so later logging cannot reinterpret a live storage bridge as an earlier value. A long-list regression checks retained text, dirty state and undo/redo back to the saved baseline.

Markdown previously shared code-number/string patterns with all languages, so list markers, dates and quoted prose changed color after delayed highlighting. The highlighting owner now excludes Markdown prose from literal rules while retaining heading/comment highlighting. Source-code numeric/string tokens and HTML/XML attributes retain their previous styling.

Native checks cover a Return key in a long file, immediate and settled scrolling, list/caret positions, single undo/redo, dark/light themes, Tab in shared-document splits and `.txt`/`.swift` Return. Document checks cover surrogate pairs, combining marks, emoji sequences, CRLF and unchanged paragraph fonts. Hardware IME and prolonged input/scroll timing require additional manual checks. See [development](development.md) for reproduction and the repository validation record for executed results.

## Executed observations

The common fixture uses 300 numbered items, a 1000×650 content area and Return at the end of item 275. The baseline uses 0.9.9 runtime sources plus test dispatch. The final fixture additionally settles initial focus/layout before measuring.

| Observation | 0.9.9 | 0.9.10 |
| --- | --- | --- |
| Scroll Y before Return (AppKit points) | 5245.5 | 5245 |
| Immediately after Return | 3425 | 5245 |
| After delayed highlighting | 3439 | 5245 |
| Character edit range (start, length) | 0, 7003 | 6402, 6 |
| List-number color | Code-number orange | Base foreground |

Focused acceptance `typing-0910-delivery` records **167 passed**: 20 core, 83 document/settings, 20 native typing and 44 split checks. It reuses those executed checks from `typing-0910-snapshots` against unchanged release/test binaries. Dark/light screenshots were inspected. Universal slices compiled; the Intel version entry ran under Rosetta and GUI checks ran on Apple Silicon. The 29 bilingual guide pairs and exported-source portability were checked separately.

The broader `typing-0910-snapshots` run remains **failed**: the Markdown product suite reported divider-drag geometry and rendered heading-link navigation failures. Comprehensive UI and final multi-window Quit were not reached in that run. Earlier probes retain native focus/menu failures, initial layout instability and text/undo discrepancies; the fixes establish fixture focus/layout and explicitly owned retained text. An isolated minimal storage probe did not reproduce the bridged-snapshot observation, so every historical failure's cause is not claimed proven. No failed run is relabeled as a full pass. Development now supports `--suite typing` to avoid unrelated repeated checks.

This is a cursor/layout stability measurement. Input latency, CPU, RSS, sustained scrolling and physical Intel/Windows GUI were not remeasured. Local logs, snapshots, screenshots and installation evidence remain in ignored `.build/test-results/` directories.
