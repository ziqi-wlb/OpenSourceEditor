# Independent Python extension host

[中文](plugins.zh-CN.md)

`Resources/plugin_host/` is an independently authored standard-library-only SDK. It loads no shipped Sublime Python code and needs no original process, license or IPC. It runs one explicitly selected local command against one snapshot and exits. It has no automatic plugin discovery, resident workers, native event listeners or full Sublime Python API compatibility claim.

Plugins are Python files running with the current user's permissions. Selecting/invoking one executes its module and command body. `-I` isolates Python search paths; it is not a sandbox.

## Input/output

```text
/usr/bin/python3 -I /ABS/Resources/plugin_host/host.py /ABS/plugin.py COMMAND
```

stdin contains UTF-8 JSON:

```json
{"text":"a😀b","selections":[[0,4]],"args":{},"settings":{}}
```

`text` and `selections` are required; optional object `args`/`settings` default to `{}`. Selections are UTF-16 `[location,length]` Swift `NSRange`, not endpoints. Extra fields, negative/bool offsets, out-of-bounds/surrogate-splitting ranges, unpaired surrogates and non-JSON NaN/Infinity are rejected. Optional CLI `ARGS_JSON` explicitly replaces stdin args.

Success writes one JSON line:

```json
{"ok":true,"text":"b😀a","selections":[[0,4]],"status":"Reversed local selections"}
```

Failure also writes one line:

```json
{"ok":false,"error":{"type":"RuntimeError","message":"..."},"text":"original text","selections":[[0,4]]}
```

Text/selections may be omitted if valid input was not parsed. Plugin failure after valid input returns the original snapshot, discarding partial text edits; external filesystem side effects are not rolled back. Ordinary import/run `print` goes to stderr. Protocol success and logical failure both exit `0`: parents must check `ok` and separately handle launch failure, timeout, signals and output limits. Error messages are capped at 4096 characters.

Input/success JSON are each limited to 8 MiB; text to 4 Mi UTF-16 units; input selections to 100000. Parents independently bound duration and stdout/stderr. There are no resident threads or delayed callbacks. The native UI compares document identity/revision before applying a successful result as one undo transaction.

## SDK scope

`sublime.py` provides Region, Selection, Settings, View, Window, Edit, status_message, active_window and `set_timeout(callback,0)`. Region endpoints preserve direction; emitted NSRange normalizes it. View size/substr/insert/erase/replace/word/line/full_line/sel use UTF-16. A compact cached array maps UTF-16 to Python indexes, invalidated on text changes.

Selection iterates snapshots. Overlapping regions and cursors on ranges merge; two nonempty regions touching only at endpoints stay separate. Merging preserves the first sorted range's direction. General replace moves points inside an edit to its new end, preserves a nonempty range's start and shifts later points by length delta. Builtin insert collapses operated selections to end cursors. These are independently tested SDK rules; native Sublime merging/movement remains unknown.

Word uses Python Unicode `\w+`. Line supports LF/CRLF, excluding terminators; full_line includes them. Selections ending exactly at the next line's beginning exclude that unselected line. Native word boundaries, text points and IME equivalence are not claimed.

View/Window run_command permit only append, insert, upper_case and lower_case. Text arrives in `characters`; case conversion uses Python strings. Other commands, including undo/redo/build/native UI, raise NotImplementedError and are not forwarded to Sublime. Settings live only in the snapshot, without disk writes or persisted settings output.

`sublime_plugin.py` provides Command, TextCommand, WindowCommand and ApplicationCommand. Only classes defined by the selected module are registered. Class aliases deduplicate; conflicting names fail. Independent naming follows observed examples: SortLinesCommand→sort_lines; HTTPServerCommand→h_tTPServer. No event is passed by default. Enable hooks accept command args or no arguments and must return bool.

Each invocation has one edit scope. TextCommand receives edit; Window/Application commands access the snapshot window. Tokens expire after scope exit; foreign Views or forged Edits cannot modify text. Failure restores the snapshot; this does not establish native edit boundaries, exception rollback, undo grouping or real window routing.

The SDK loads its own sublime modules first, then adds only the selected plugin's parent for sibling imports. `-I` excludes the invoking directory/Python environment. No user Packages, plugin_loaded/unloaded, delayed callbacks or original product code are loaded. Plugins modifying import machinery/sys.stdout/global state exceed ordinary-print isolation.

## Examples and validation

`demo_plugin.py` offers reverse_selection (reverse Unicode codepoints) and prefix_selection (`args.prefix`). Reversal preserves surrogate pairs but does not promise intact combining/emoji grapheme clusters.

```text
python3 tests/plugin_host_test.py
```

Of 17 tests, 16 use independent public CLI subprocesses; one directly checks token expiry on successful/exceptional scope exit. Coverage includes UTF-16 emoji, multiple selections, Region direction, CRLF/word, stdout isolation, rollback, Edit ownership, synchronous callback/settings, no-argument enable hooks, disabled commands, args overrides, SDK import priority, strict input and unsupported undo/async. Authored plugins do not establish native Sublime compatibility or performance.

The full original API, resident worker/native IPC, events/UI/async, project/build hosts and shared plugin state remain unsupported. Native Swift owns editing history; workers do not persist undo/redo.
