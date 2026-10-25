import Foundation

enum PreferencesTestRunner {
    static func run() -> Int32 {
        var results: [[String: Any]] = []
        func test(_ name: String, _ body: () throws -> Void) {
            do { try body(); results.append(["name": name, "status": "passed"]) }
            catch { results.append(["name": name, "status": "failed", "error": String(describing: error)]) }
        }
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw EditorFailure.invalidEdit(message) }
        }
        func rejected(_ source: String) -> Bool {
            do { _ = try EditorConfiguration.parse(Data(source.utf8)); return false } catch { return true }
        }
        test("Mac defaults and automatic wrapping distinguish source from prose") {
            let c = EditorConfiguration()
            try require(c.fontName == "Menlo" && c.fontSize == 12 && c.defaultFontSize == 12, "Mac font defaults differ")
            try require(c.tabSize == 4 && !c.translateTabsToSpaces && c.useTabStops && c.autoIndent && c.detectIndentation, "Indent defaults differ")
            try require(!c.wrapsText(isSourceCode: true) && c.wrapsText(isSourceCode: false), "auto wrapping is not syntax-sensitive")
        }
        test("Workspace restoration defaults on for new and existing preferences") {
            try require(EditorConfiguration().rememberWorkspace && EditorConfiguration.parse(Data("{}".utf8)).rememberWorkspace, "Workspace restoration must default on")
            try require(rejected(#"{"remember_workspace":"false"}"#), "Wrong workspace preference type accepted")
        }
        test("Native snake-case settings and original indentation switches") {
            let c = try EditorConfiguration.parse(Data(#"{"font_face":"Menlo","font_size":18,"default_font_size":14,"tab_size":128,"translate_tabs_to_spaces":true,"detect_indentation":false,"use_tab_stops":false,"auto_indent":false,"smart_indent":false,"shift_tab_unindent":true,"word_wrap":false}"#.utf8))
            try require(c.tabSize == 128 && c.translateTabsToSpaces && !c.detectIndentation && !c.useTabStops && !c.autoIndent && !c.smartIndent && c.shiftTabUnindent && !c.wordWrap, "Native settings were not applied")
        }
        test("Existing camel-case config remains readable") {
            let c = try JSONDecoder().decode(EditorConfiguration.self, from: Data(#"{"fontName":"Menlo","fontSize":16,"tabSize":2,"wordWrap":true,"keyBindings":{"build":"Control+Option+K"}}"#.utf8))
            try require(c.fontSize == 16 && c.tabSize == 2 && c.wordWrapMode == .enabled && c.keyBindings["build"]?.source == "Control+Option+K", "Existing settings changed")
        }
        test("Conflicting aliases fail, aligned aliases normalize once") {
            try require(rejected(#"{"tab_size":2,"tabSize":4}"#), "Ambiguous settings accepted")
            let c = try EditorConfiguration.parse(Data(#"{"tab_size":4,"tabSize":4,"word_wrap":"auto","wordWrap":"auto"}"#.utf8))
            try require(c.tabSize == 4 && c.wordWrapMode == .automatic, "Aligned aliases rejected")
        }
        test("JSONC strings, URLs, escapes, Unicode and nested trailing commas retain content") {
            let source = #"{"font_face":"Menlo",/* block */"tab_size":2,"word_wrap":"auto","ignored":{"url":"https://example.test/a//b","text":"quote\" /*literal*/ 中文","list":[1,2,],}, // line"# + "\n}"
            let normalized = try SettingsJSON.normalized(Data(source.utf8))
            let json = try JSONSerialization.jsonObject(with: normalized) as! [String: Any]
            let nested = json["ignored"] as! [String: Any]
            try require(nested["url"] as? String == "https://example.test/a//b" && nested["text"] as? String == "quote\" /*literal*/ 中文", "String bytes were changed by comment parsing")
            try require(try EditorConfiguration.parse(Data(source.utf8)).tabSize == 2, "JSONC could not be loaded")
        }
        test("Malformed commas, comments, strings and wrong types fail explicitly") {
            for source in ["{,}", "{\"tab_size\":,}", "{\"tab_size\":true}", "{\"tab_size\":-1}", "{\"tab_size\":0}", "{ /*unterminated", "{\"font_face\":\"unfinished}", "{\"word_wrap\":\"maybe\"}", "{\"font_size\":0}"] {
                try require(rejected(source), "Invalid settings accepted: \(source)")
            }
        }
        test("Settings size and encoding boundaries are enforced") {
            do { _ = try SettingsJSON.normalized(Data([0xff])); throw EditorFailure.invalidEdit("Invalid UTF-8 accepted") }
            catch let error as EditorFailure { if String(describing: error).contains("accepted") { throw error } }
            let valid = Data(("{}" + String(repeating: " ", count: 1024 * 1024 - 2)).utf8)
            _ = try EditorConfiguration.parse(valid)
            try require(rejected(String(decoding: valid + Data([32]), as: UTF8.self)), "Excessive settings accepted")
        }
        test("Save then load preserves settings and caller shortcut spelling") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("source-editor-preferences-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("Preferences.sublime-settings")
            var c = EditorConfiguration()
            c.tabSize = 8; c.translateTabsToSpaces = true; c.wordWrapMode = .automatic; c.rememberWorkspace = false
            c.keyBindings["build"] = try EditorKeyBinding.parse("Control+Option+K")
            try c.save(file)
            let restored = try EditorConfiguration.load(file)
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            try require(restored.tabSize == 8 && restored.translateTabsToSpaces && restored.wordWrapMode == .automatic && restored.keyBindings["build"]?.source == "Control+Option+K", "Settings lost during save/load")
            try require(json["tab_size"] as? Int == 8 && json["tabSize"] == nil, "Save did not use canonical native key")
            try require(!restored.rememberWorkspace && json["remember_workspace"] as? Bool == false, "Workspace switch lost during save/load")
        }
        let failed = results.filter { $0["status"] as? String == "failed" }.count
        let result: [String: Any] = ["suite": "source-editor-preferences", "passed": results.count - failed, "failed": failed,
                                   "results": results, "target_runtime_executed": false]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
        return failed == 0 ? 0 : 1
    }
}
