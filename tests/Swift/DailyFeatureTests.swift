import AppKit

enum DailyFeatureTests {
    static let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEElEQVR4nGNg+P//PxjDGABlrAv1EPkwzAAAAABJRU5ErkJggg==")!
    static func run() -> Int32 {
        var passed = 0, failures: [String] = [], metrics: [String: Double] = [:]
        func check(_ name: String, _ value: Bool) { if value { passed += 1 } else { failures.append(name) } }
        func rejects(_ name: String, _ body: () throws -> Void) { do { try body(); check(name, false) } catch { check(name, true) } }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/daily-fixtures-" + UUID().uuidString).standardizedFileURL.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = EditorDesktopStore(directory: directory.appendingPathComponent("state"))
            check("Fresh preferences absent", try store.loadConfiguration() == nil)
            var config = EditorConfiguration(); config.fontSize = 17; config.theme = "light"; config.tabSize = 2
            try store.saveConfiguration(config)
            let loaded = try store.loadConfiguration()!
            check("Preferences roundtrip", loaded.fontSize == 17 && loaded.theme == "light" && loaded.tabSize == 2)
            let prefs = store.directory.appendingPathComponent("preferences.json")
            let damaged = Data("{broken".utf8); try damaged.write(to: prefs)
            rejects("Malformed preferences rejected") { _ = try store.loadConfiguration() }
            check("Malformed preferences preserved", try Data(contentsOf: prefs) == damaged)
            try store.saveConfiguration(config)
            check("Malformed predecessor backed up", try Data(contentsOf: store.directory.appendingPathComponent("preferences.json.previous")) == damaged)
            let permissions = try FileManager.default.attributesOfItem(atPath: prefs.path)[.posixPermissions] as? Int
            check("Preferences private permissions", permissions == 0o600)
            let saved = SavedWorkspace(files: [.init(path: directory.appendingPathComponent("note.md").path, settings: .init(), encoding: .utf8,
                selections: [[1, 0]], markdownMode: "sideBySide")], selectedPath: nil, projectPath: directory.path, split: true, sidebarVisible: true, frame: [10, 10, 1000, 700], scrollY: 12)
            try store.saveDesktop(SavedDesktop(workspaces: [saved]))
            check("Desktop metadata roundtrip", try store.loadDesktop()?.workspaces[0].files[0].markdownMode == "sideBySide")
            var hiddenChrome = saved
            hiddenChrome.tabsVisible = false; hiddenChrome.statusVisible = false; hiddenChrome.lineNumbersVisible = false
            try store.saveDesktop(SavedDesktop(workspaces: [hiddenChrome]))
            let restoredChrome = try store.loadDesktop()?.workspaces[0]
            check("Hidden chrome preferences survive desktop serialization", restoredChrome?.tabsVisible == false && restoredChrome?.statusVisible == false && restoredChrome?.lineNumbersVisible == false)
            let legacy = try JSONDecoder().decode(SavedWorkspace.self, from: JSONEncoder().encode(saved))
            check("Legacy workspaces omit new chrome preferences safely", legacy.tabsVisible == nil && legacy.statusVisible == nil && legacy.lineNumbersVisible == nil)
            var closed = saved
            closed.sidebar = .init(expandedFolders: ["", "笔记", "笔记/中文😀"], selectedPath: "笔记/中文😀", scrollY: 50)
            try store.saveDesktop(.init(workspaces: [], lastClosedWorkspace: closed))
            let last = try store.loadDesktop()?.lastClosedWorkspace
            check("Closed folder and Unicode sidebar roundtrip", last?.projectPath == saved.projectPath && last?.sidebar?.selectedPath == "笔记/中文😀" && last?.sidebar?.expandedFolders.count == 3 && last?.sidebar?.scrollY == 50)
            for path in ["/absolute", "../escape", "a/./b", "a//b"] {
                var invalidSidebar = closed; invalidSidebar.sidebar?.selectedPath = path
                rejects("Invalid closed sidebar path rejected: " + path) { try store.saveDesktop(.init(workspaces: [], lastClosedWorkspace: invalidSidebar)) }
            }
            var invalidSidebar = closed; invalidSidebar.sidebar?.scrollY = -1
            rejects("Invalid closed sidebar scroll rejected") { try store.saveDesktop(.init(workspaces: [], lastClosedWorkspace: invalidSidebar)) }
            let suite = "org.sourceeditor.tests.recent." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let files = RecentLocations(defaults: defaults), folders = RecentLocations(defaults: defaults, kind: .folders)
            let recentFolder = directory.appendingPathComponent("folder"), movedFolder = directory.appendingPathComponent("moved-folder")
            files.note(directory.appendingPathComponent("note.md")); folders.note(recentFolder); folders.note(recentFolder)
            check("File and folder MRU keys are separate and deduplicated", files.urls.count == 1 && folders.urls == [recentFolder])
            folders.relocate(from: recentFolder, to: movedFolder)
            check("Folder MRU relocation and reload", RecentLocations(defaults: defaults, kind: .folders).urls == [movedFolder])
            folders.clear()
            check("Clearing recent folders preserves recent files", RecentLocations(defaults: defaults, kind: .folders).urls.isEmpty && RecentLocations(defaults: defaults).urls == files.urls)
            var invalid = saved; invalid.frame[0] = .infinity
            rejects("Nonfinite geometry rejected") { try store.saveDesktop(.init(workspaces: [invalid])) }
            invalid = saved; invalid.files[0].selections = [[-1, 0]]
            rejects("Negative selection rejected") { try store.saveDesktop(.init(workspaces: [invalid])) }
            invalid = saved; invalid.files += invalid.files
            rejects("Duplicate file identities rejected") { try store.saveDesktop(.init(workspaces: [invalid])) }
            rejects("Window state bounded") { try store.saveDesktop(.init(workspaces: Array(repeating: saved, count: 33))) }
            let recoveryFolder = directory.appendingPathComponent("Recovery")
            try FileManager.default.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
            let candidate = recoveryFolder.appendingPathComponent("crash.json"); try Data("malformed but preserved".utf8).write(to: candidate)
            let live = EditorRecovery(directory: recoveryFolder)
            try Data("live".utf8).write(to: live.url)
            check("Recovery catalog excludes live owner without parsing", RecoveryCandidate.discover(in: recoveryFolder).map(\.url) == [candidate])

            var settings = DocumentSettings(); settings.syntax = "markdown"; settings.translateTabsToSpaces = true
            for (name, source, expected) in [
                ("Bullet", "- item", "- item\n- "), ("Ordered", "9. item", "9. item\n10. "),
                ("Task reset", "- [x] done", "- [x] done\n- [ ] "), ("Empty item terminates", "- ", "\n"),
                ("Quote continues", "> 中文😀", "> 中文😀\n> "), ("Empty quote terminates", "> ", "\n"),
                ("Fence preserves code", "```md\n- code", "```md\n- code\n"),
                ("False fence closer stays code", "```\n```info\n- code", "```\n```info\n- code\n"),
                ("Longer closer ends fence", "```\ncode\n````\n- list", "```\ncode\n````\n- list\n- ")
            ] {
                let result = NoteEditing.newline(in: source, selections: [.init(location: source.utf16.count, length: 0)], settings: settings)
                check("Markdown Enter: " + name, result.error == nil && result.text == expected && result.selections == [.init(location: expected.utf16.count, length: 0)])
            }
            settings.lineEnding = .crlf
            check("Markdown CRLF", NoteEditing.newline(in: "- 😀", selections: [.init(location: 4, length: 0)], settings: settings).text == "- 😀\r\n- ")
            let tasks = "- [ ] outside\n```\n- [ ] code\n```extra\n- [x] still code\n```\n- [x] done"
            let toggled = NoteEditing.toggleTasks(in: tasks, selections: [.init(location: 0, length: tasks.utf16.count)])
            check("Task toggles skip all fenced lines", toggled.text == tasks.replacingOccurrences(of: "- [ ] outside", with: "- [x] outside"))
            let two = NoteEditing.newline(in: "- a\n- b", selections: [.init(location: 3, length: 0), .init(location: 7, length: 0)], settings: settings)
            check("Multiple Markdown cursors", two.text == "- a\r\n- \n- b\r\n- " && two.selections.count == 2)
            let wrapped = NoteEditing.wrap("😀 x", selections: [.init(location: 0, length: 2), .init(location: 3, length: 1)], opening: "**", closing: "**")
            check("Formatting preserves Unicode selections", wrapped.text == "**😀** **x**" && wrapped.selections == [.init(location: 2, length: 2), .init(location: 9, length: 1)])
            check("Python colon indentation", EditorSyntax.python.shouldIndent("def f(): # comment"))
            check("Python quoted/comment colons ignored", !EditorSyntax.python.shouldIndent("value = 'if:'") && !EditorSyntax.python.shouldIndent("print(x) # if ready:"))
            check("Python dictionary is not block", !EditorSyntax.python.shouldIndent("key:"))
            check("Language resolution unified", EditorSyntax.resolve("rb") == .ruby && EditorSyntax.resolve("java") == .java && EditorSyntax.resolve("toml") == .toml)
            let sql = SyntaxHighlights(text: "SELECT x FROM t -- note", syntax: "sql")
            check("SQL keyword and comment highlighting", sql.groups.count == 4 && sql.groups[0].count == 2 && sql.groups[3].count == 1)
            check("Ruby/TOML comments", ["rb", "toml"].allSatisfy { SyntaxHighlights(text: "x = 1 # note", syntax: $0).groups[3].count == 1 })

            let project = directory.appendingPathComponent("project"); try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let operations = ProjectFileOperations(root: project)
            let original = try operations.create(in: project, name: "Note.md", directory: false)
            try "disk".write(to: original, atomically: true, encoding: .utf8)
            let renamed = try operations.move(original, to: project.appendingPathComponent("note.md"))
            check("Case-only rename", try String(contentsOf: renamed, encoding: .utf8) == "disk")
            let collision = try operations.create(in: project, name: "other.md", directory: false)
            rejects("Destination never overwritten") { _ = try operations.move(renamed, to: collision) }
            rejects("Parent escape rejected") { _ = try operations.create(in: project, name: "../escape", directory: false) }
            rejects("Root destructive operation rejected") { _ = try operations.trash(project) }
            rejects("Out-of-project move rejected") { _ = try operations.move(renamed, to: directory.appendingPathComponent("escape.md")) }
            let folder = try operations.create(in: project, name: "folder", directory: true)
            rejects("Move into own subtree rejected") { _ = try operations.move(folder, to: folder.appendingPathComponent("inside")) }
            check("Component-based rebasing", ProjectFileOperations.rebase(project.appendingPathComponent("folder/a"), from: folder, to: project.appendingPathComponent("moved"))?.lastPathComponent == "a" && ProjectFileOperations.rebase(project.appendingPathComponent("folder-sibling/a"), from: folder, to: project) == nil)
            let outside = directory.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("link"), withDestinationURL: outside)
            rejects("Linked parent cannot escape project") { _ = try operations.create(in: project.appendingPathComponent("link"), name: "no.txt", directory: false) }
            let recent = RecentLocations(defaults: nil); recent.note(renamed); recent.relocate(from: renamed, to: collision)
            check("Recent-file identity relocated", recent.urls == [collision])
            let image = try NoteAssets.insertImage(pixel, beside: renamed)
            let image2 = try NoteAssets.insertImage(pixel, beside: renamed)
            check("PNG attachments relative and unique", image.url != image2.url && image.markdown.hasPrefix("![image](assets/") && FileManager.default.fileExists(atPath: image.url.path))
            rejects("Invalid image rejected") { _ = try NoteAssets.insertImage(Data([1,2,3]), beside: renamed) }
            try FileManager.default.createSymbolicLink(at: outside.appendingPathComponent("assets"), withDestinationURL: project)
            rejects("Attachment symlink outside note scope rejected") { _ = try NoteAssets.insertImage(pixel, beside: outside.appendingPathComponent("note.md")) }

            check("Context-sensitive regex replacement", try SearchEngine.replacing(in: "abc abc", query: "(?<=a)bc", replacement: "Y", regex: true, range: .init(location: 1, length: 2)).text == "aY abc")
            check("Regex captures", try SearchEngine.replacing(in: "a1 b2", query: "([a-z])(\\d)", replacement: "$2$1", regex: true).text == "1a 2b")
            check("Replacement preserves Unicode offsets", try SearchEngine.replacing(in: "😀é 😀é", query: "é", replacement: "汉字").text == "😀汉字 😀汉字")
            check("Zero-width regex finite", try SearchEngine.find(in: "abc", query: "(?=.)", regex: true).count == 3)
            let many = String(repeating: "a", count: SearchEngine.maximumMatches + 1)
            let scan = try SearchEngine.scan(in: many, query: "a")
            check("Search cap reports partial", scan.matches.count == SearchEngine.maximumMatches && scan.limit != nil)
            rejects("Partial search never replaces") { _ = try SearchEngine.replacing(in: many, query: "a", replacement: "b") }
            rejects("Search query bounded") { _ = try SearchEngine.find(in: "x", query: String(repeating: "x", count: 4097)) }
            rejects("Search input bounded") { _ = try SearchEngine.find(in: String(repeating: "x", count: SearchEngine.maximumUTF16 + 1), query: "x") }
            rejects("Replacement expanded before allocation", { _ = try SearchEngine.replacing(in: String(repeating: "a", count: 10000), query: "(a+)", replacement: String(repeating: "$1", count: 2000), regex: true) })
            let replacementStart = ProcessInfo.processInfo.systemUptime
            let bulk = try SearchEngine.replacing(in: String(repeating: "a", count: 40_000), query: "a", replacement: "xyz")
            metrics["bulk_replace_40000_seconds"] = ProcessInfo.processInfo.systemUptime - replacementStart
            check("Large replacement builds complete output", bulk.text.utf16.count == 120_000 && bulk.selections.count == 40_000 && bulk.selections.last == .init(location: 120_000, length: 0))
            let began = ProcessInfo.processInfo.systemUptime
            let pathological = try SearchEngine.scan(in: String(repeating: "a", count: 10000) + "!", query: "(a+)+$", regex: true)
            metrics["pathological_regex_seconds"] = ProcessInfo.processInfo.systemUptime - began
            check("ICU backtracking interrupted", pathological.limit?.contains("time limit") == true && metrics["pathological_regex_seconds"]! < 2)
            check("Search cancellation", try SearchEngine.scan(in: many, query: "a", isCancelled: { true }).limit == "Search cancelled")
        } catch { failures.append("Unexpected: " + error.localizedDescription) }
        let output: [String: Any] = ["passed": passed, "failed": failures.count, "failures": failures, "metrics": metrics]
        print(String(data: try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
        return failures.isEmpty ? 0 : 1
    }
}
