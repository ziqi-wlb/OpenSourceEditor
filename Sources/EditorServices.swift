import AppKit
import Darwin

struct EditorKeyBinding {
    let source: String
    let keyEquivalent: String
    let modifiers: NSEvent.ModifierFlags
    static func parse(_ source: String) throws -> EditorKeyBinding {
        let parts = source.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.last, key.count == 1 else { throw EditorFailure.invalidEdit("Shortcut must end with a single key: \(source)") }
        var flags: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "super": flags.insert(.command)
            case "ctrl", "control": flags.insert(.control)
            case "alt", "option": flags.insert(.option)
            case "shift": flags.insert(.shift)
            default: throw EditorFailure.invalidEdit("Unknown shortcut modifier: \(part)")
            }
        }
        return EditorKeyBinding(source: source, keyEquivalent: key, modifiers: flags)
    }
}

enum EditorWordWrapMode: String, Codable {
    case enabled, disabled, automatic
}

struct EditorConfiguration: Codable {
    var fontName = "Menlo"
    var fontSize: Double = 12
    var defaultFontSize: Double = 12
    var tabSize = 4
    var translateTabsToSpaces = false
    var detectIndentation = true
    var useTabStops = true
    var autoIndent = true
    var smartIndent = true
    var shiftTabUnindent = false
    var wordWrapMode = EditorWordWrapMode.automatic
    var wordWrap: Bool {
        get { wordWrapMode != .disabled }
        set { wordWrapMode = newValue ? .enabled : .disabled }
    }
    var theme = "dark"
    var rememberWorkspace = true
    var keyBindings: [String: EditorKeyBinding] = [:]
    enum CodingKeys: String, CodingKey {
        case fontName, fontSize, defaultFontSize, tabSize, translateTabsToSpaces, detectIndentation
        case useTabStops, autoIndent, smartIndent, shiftTabUnindent, wordWrap, theme, keyBindings
        case fontFace = "font_face", font_size, default_font_size, tab_size, translate_tabs_to_spaces, detect_indentation
        case use_tab_stops, auto_indent, smart_indent, shift_tab_unindent, word_wrap
        case remember_workspace
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable & Equatable>(_ type: T.Type, _ native: CodingKeys, _ legacy: CodingKeys, _ fallback: T) throws -> T {
            let a = try c.decodeIfPresent(type, forKey: native), b = try c.decodeIfPresent(type, forKey: legacy)
            if let a, let b, a != b { throw EditorFailure.invalidEdit("Conflicting settings: \(native.rawValue) and \(legacy.rawValue).") }
            return a ?? b ?? fallback
        }
        fontName = try value(String.self, .fontFace, .fontName, fontName)
        fontSize = try value(Double.self, .font_size, .fontSize, fontSize)
        defaultFontSize = try value(Double.self, .default_font_size, .defaultFontSize, defaultFontSize)
        tabSize = try value(Int.self, .tab_size, .tabSize, tabSize)
        translateTabsToSpaces = try value(Bool.self, .translate_tabs_to_spaces, .translateTabsToSpaces, translateTabsToSpaces)
        detectIndentation = try value(Bool.self, .detect_indentation, .detectIndentation, detectIndentation)
        useTabStops = try value(Bool.self, .use_tab_stops, .useTabStops, useTabStops)
        autoIndent = try value(Bool.self, .auto_indent, .autoIndent, autoIndent)
        smartIndent = try value(Bool.self, .smart_indent, .smartIndent, smartIndent)
        shiftTabUnindent = try value(Bool.self, .shift_tab_unindent, .shiftTabUnindent, shiftTabUnindent)
        func wrap(_ key: CodingKeys) throws -> EditorWordWrapMode? {
            guard c.contains(key), try !c.decodeNil(forKey: key) else { return nil }
            if let enabled = try? c.decode(Bool.self, forKey: key) { return enabled ? .enabled : .disabled }
            if (try? c.decode(String.self, forKey: key)) == "auto" { return .automatic }
            throw EditorFailure.invalidEdit("\(key.rawValue) must be true, false or auto.")
        }
        let nativeWrap = try wrap(.word_wrap), legacyWrap = try wrap(.wordWrap)
        if let nativeWrap, let legacyWrap, nativeWrap != legacyWrap { throw EditorFailure.invalidEdit("Conflicting word wrap settings.") }
        wordWrapMode = nativeWrap ?? legacyWrap ?? wordWrapMode
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? theme
        rememberWorkspace = try c.decodeIfPresent(Bool.self, forKey: .remember_workspace) ?? rememberWorkspace
        let bindings = try c.decodeIfPresent([String: String].self, forKey: .keyBindings) ?? [:]
        keyBindings = try bindings.mapValues(EditorKeyBinding.parse)
        guard fontSize.isFinite, fontSize > 0, defaultFontSize.isFinite, defaultFontSize > 0,
              tabSize > 0, ["light", "dark"].contains(theme) else {
            throw EditorFailure.invalidEdit("Configuration needs positive finite font sizes, a positive tab_size and theme light/dark.")
        }
    }
    func wrapsText(isSourceCode: Bool) -> Bool {
        switch wordWrapMode {
        case .enabled: return true
        case .disabled: return false
        case .automatic: return !isSourceCode
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fontName, forKey: .fontFace)
        try c.encode(fontSize, forKey: .font_size)
        try c.encode(defaultFontSize, forKey: .default_font_size)
        try c.encode(tabSize, forKey: .tab_size)
        try c.encode(translateTabsToSpaces, forKey: .translate_tabs_to_spaces)
        try c.encode(detectIndentation, forKey: .detect_indentation)
        try c.encode(useTabStops, forKey: .use_tab_stops)
        try c.encode(autoIndent, forKey: .auto_indent)
        try c.encode(smartIndent, forKey: .smart_indent)
        try c.encode(shiftTabUnindent, forKey: .shift_tab_unindent)
        if wordWrapMode == .automatic { try c.encode("auto", forKey: .word_wrap) }
        else { try c.encode(wordWrapMode == .enabled, forKey: .word_wrap) }
        try c.encode(theme, forKey: .theme)
        try c.encode(rememberWorkspace, forKey: .remember_workspace)
        try c.encode(keyBindings.mapValues(\.source), forKey: .keyBindings)
    }
    static func load(_ url: URL) throws -> EditorConfiguration {
        try parse(boundedJSON(url))
    }
    static func parse(_ data: Data) throws -> EditorConfiguration {
        try JSONDecoder().decode(Self.self, from: SettingsJSON.normalized(data))
    }
    func save(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

private func boundedJSON(_ url: URL) throws -> Data {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let data = try file.read(upToCount: 1024 * 1024 + 1) ?? Data()
    guard data.count <= 1024 * 1024 else { throw EditorFailure.invalidEdit("Configuration exceeds 1 MiB.") }
    return data
}

struct BuildSpec: Decodable {
    var argv: [String]?
    var shellCommand: String?
    var workingDirectory: String?
    var timeoutSeconds: Double = 300
    enum CodingKeys: String, CodingKey { case argv, shellCommand, workingDirectory, timeoutSeconds }
    init(argv: [String], workingDirectory: String? = nil, timeoutSeconds: Double = 300) {
        self.argv = argv; self.workingDirectory = workingDirectory; self.timeoutSeconds = timeoutSeconds
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        argv = try c.decodeIfPresent([String].self, forKey: .argv)
        shellCommand = try c.decodeIfPresent(String.self, forKey: .shellCommand)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 300
        try validate()
    }
    func validate() throws {
        guard (argv != nil) != (shellCommand != nil), argv == nil || !(argv?.isEmpty ?? true),
              timeoutSeconds.isFinite, (0.1...3600).contains(timeoutSeconds),
              !(argv ?? []).contains(where: { $0.contains("\0") }), !(shellCommand ?? "").contains("\0") else {
            throw EditorFailure.invalidEdit("Build requires exactly one argv or shellCommand and timeoutSeconds 0.1–3600.")
        }
    }
    static func load(_ url: URL) throws -> BuildSpec { try JSONDecoder().decode(Self.self, from: boundedJSON(url)) }
}

// A spawned process owns a new process group. Its root remains unreaped until
// group cleanup, preventing PID reuse between cancellation and cleanup.
private final class OwnedCommand {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private(set) var reason: String?
    private var output = Data()
    private var totalBytes = 0
    private let cap: Int
    private let log: FileHandle
    private let onOutput: (String) -> Void
    private let completion: (Int32, Data, String?) -> Void
    init(cap: Int, log: FileHandle, onOutput: @escaping (String) -> Void,
         completion: @escaping (Int32, Data, String?) -> Void) {
        self.cap = cap; self.log = log; self.onOutput = onOutput; self.completion = completion
    }
    func start(argv: [String], cwd: URL, input: Data?, separateOutput: Bool, timeout: Double,
               extraEnvironment: [String: String]) throws {
        var outFD: [Int32] = [0, 0], errFD: [Int32] = [0, 0]
        guard pipe(&outFD) == 0 else { throw EditorFailure.invalidEdit("Cannot create process pipes.") }
        guard pipe(&errFD) == 0 else { outFD.forEach { close($0) }; throw EditorFailure.invalidEdit("Cannot create process pipes.") }
        var handedOff = false
        defer { if !handedOff { (outFD + errFD).forEach { close($0) } } }
        let inputURL = FileManager.default.temporaryDirectory.appendingPathComponent("source-editor-input-\(UUID().uuidString)")
        try (input ?? Data()).write(to: inputURL, options: .atomic)
        let inputFD = open(inputURL.path, O_RDONLY)
        try? FileManager.default.removeItem(at: inputURL)
        guard inputFD >= 0 else { throw EditorFailure.invalidEdit("Cannot create process input.") }
        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attr)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr) }
        posix_spawn_file_actions_adddup2(&actions, inputFD, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outFD[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, separateOutput ? errFD[1] : outFD[1], STDERR_FILENO)
        for fd in outFD + errFD + [inputFD] { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawn_file_actions_addchdir_np(&actions, cwd.path)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        var strings = argv.map { strdup($0) }
        strings.append(nil)
        var environment = ProcessInfo.processInfo.environment
        environment.merge(extraEnvironment) { _, new in new }
        var env = environment.map { strdup("\($0.key)=\($0.value)") }; env.append(nil)
        defer { for s in strings + env { free(s) } }
        var child: pid_t = 0
        let code = posix_spawnp(&child, argv[0], &actions, &attr, &strings, &env)
        close(inputFD); close(outFD[1]); close(errFD[1])
        handedOff = true
        guard code == 0 else { close(outFD[0]); close(errFD[0]); throw EditorFailure.invalidEdit("Cannot start command: \(String(cString: strerror(code)))") }
        lock.lock(); pid = child; lock.unlock()
        let readers = DispatchGroup()
        for (fd, isResult) in [(outFD[0], separateOutput), (errFD[0], false)] {
            readers.enter()
            DispatchQueue.global().async {
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                var pending = Data()
                while let chunk = try? handle.read(upToCount: 8192), !chunk.isEmpty {
                    self.lock.lock()
                    self.totalBytes += chunk.count
                    let over = self.totalBytes > self.cap
                    if !over {
                        if isResult { self.output.append(chunk) }
                        else { try? self.log.write(contentsOf: chunk) }
                    }
                    self.lock.unlock()
                    if over { self.cancel(reason: "Output exceeded \(self.cap) bytes."); continue }
                    if !isResult {
                        pending.append(chunk)
                        var end = pending.count
                        // Retain an incomplete trailing UTF-8 sequence across read boundaries.
                        if let last = pending.indices.reversed().prefix(4).first(where: { pending[$0] & 0xc0 != 0x80 }) {
                            let first = pending[last]
                            let expected = first < 0x80 ? 1 : first & 0xe0 == 0xc0 ? 2 : first & 0xf0 == 0xe0 ? 3 : first & 0xf8 == 0xf0 ? 4 : 1
                            if pending.count - last < expected { end = last }
                        }
                        if end > 0 {
                            let text = String(decoding: pending.prefix(end), as: UTF8.self)
                            pending = Data(pending.dropFirst(end))
                            DispatchQueue.main.async { self.onOutput(text) }
                        }
                    }
                }
                if !pending.isEmpty {
                    let text = String(decoding: pending, as: UTF8.self)
                    DispatchQueue.main.async { self.onOutput(text) }
                }
                try? handle.close()
                readers.leave()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.cancel(reason: "Command timed out after \(timeout) seconds.") }
        DispatchQueue.global().async {
            var info = siginfo_t()
            var rc: Int32
            repeat { rc = waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) } while rc == -1 && errno == EINTR
            self.lock.lock()
            // The root is still waitable here, so its group ID cannot be reused.
            if rc == 0 { kill(-child, SIGKILL) }
            var status: Int32 = 0
            while waitpid(child, &status, 0) == -1 && errno == EINTR {}
            self.pid = 0
            self.lock.unlock()
            readers.wait()
            try? self.log.close()
            let exitCode = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            DispatchQueue.main.async { self.completion(exitCode, self.output, self.reason) }
        }
    }
    func cancel(reason: String = "Command cancelled.") {
        lock.lock()
        guard pid != 0 else { lock.unlock(); return }
        self.reason = self.reason ?? reason
        let child = pid
        kill(-child, SIGTERM)
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if self.pid == child { kill(-child, SIGKILL) }
        }
    }
}

final class BuildRunner {
    private var command: OwnedCommand?
    private(set) var logURL: URL?
    private(set) var isRunning = false
    func start(spec: BuildSpec, documentURL: URL?, projectURL: URL?, onOutput: @escaping (String) -> Void,
               onCompletion: @escaping (Int32) -> Void) throws {
        try spec.validate()
        let directory = projectURL ?? documentURL?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
        let substitutions = ["${file}": documentURL?.path ?? "", "${project}": projectURL?.path ?? ""]
        func expand(_ source: String) -> String { substitutions.reduce(source) { $0.replacingOccurrences(of: $1.key, with: $1.value) } }
        let argv = spec.argv?.map(expand) ?? ["/bin/sh", "-c", spec.shellCommand!]
        let cwd = spec.workingDirectory.map { URL(fileURLWithPath: expand($0), relativeTo: directory).standardizedFileURL } ?? directory
        try launch(argv: argv, cwd: cwd, input: nil, separateOutput: false, cap: 64 * 1024 * 1024,
                   timeout: spec.timeoutSeconds, environment: ["SOURCE_EDITOR_FILE": documentURL?.path ?? "", "SOURCE_EDITOR_PROJECT": projectURL?.path ?? ""],
                   onOutput: onOutput) { code, _, reason in
            if let reason { onOutput("\n\(reason)\n") }
            onCompletion(code)
        }
    }
    fileprivate func launch(argv: [String], cwd: URL, input: Data?, separateOutput: Bool, cap: Int, timeout: Double,
                            environment: [String: String] = [:], onOutput: @escaping (String) -> Void,
                            completion: @escaping (Int32, Data, String?) -> Void) throws {
        guard !isRunning else { throw EditorFailure.invalidEdit("A command is already running.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SourceEditor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        logURL = directory.appendingPathComponent("build.log")
        FileManager.default.createFile(atPath: logURL!.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL!)
        let owned = OwnedCommand(cap: cap, log: log, onOutput: onOutput) { [weak self] code, data, reason in
            self?.isRunning = false; self?.command = nil
            completion(code, data, reason)
        }
        command = owned; isRunning = true
        do { try owned.start(argv: argv, cwd: cwd, input: input, separateOutput: separateOutput, timeout: timeout, extraEnvironment: environment) }
        catch { isRunning = false; command = nil; try? log.close(); throw error }
    }
    func cancel() { command?.cancel() }
}

enum PluginRunner {
    @discardableResult static func run(pythonURL: URL, pluginURL: URL, command: String, args: [String: Any],
                                     text: String, selections: [NSRange], completion: @escaping (Result<TextEditResult, Error>) -> Void) -> BuildRunner {
        let runner = BuildRunner()
        do {
            guard let host = Bundle.main.resourceURL?.appendingPathComponent("plugin_host/host.py"),
                  FileManager.default.fileExists(atPath: host.path) else { throw EditorFailure.invalidEdit("Bundled plugin host is missing.") }
            let input = try JSONSerialization.data(withJSONObject: ["text": text, "selections": selections.map { [$0.location, $0.length] }, "args": args])
            guard input.count <= 8 * 1024 * 1024 else { throw EditorFailure.invalidEdit("Plugin input exceeds 8 MiB.") }
            try runner.launch(argv: [pythonURL.path, "-I", "-B", host.path, pluginURL.path, command], cwd: pluginURL.deletingLastPathComponent(),
                              input: input, separateOutput: true, cap: 8 * 1024 * 1024, timeout: 30, onOutput: { _ in }) { code, output, reason in
                do {
                    guard reason == nil, code == 0 else { throw EditorFailure.invalidEdit(reason ?? "Plugin process exited \(code). Log: \(runner.logURL?.path ?? "")") }
                    guard let object = try JSONSerialization.jsonObject(with: output) as? [String: Any], object["ok"] as? Bool == true,
                          let resultText = object["text"] as? String, let ranges = object["selections"] as? [[Int]] else {
                        let object = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any]
                        let error = object?["error"] as? [String: Any]
                        throw EditorFailure.invalidEdit(error?["message"] as? String ?? "Plugin returned invalid or failed result.")
                    }
                    let nsRanges = try ranges.map { r -> NSRange in
                        guard r.count == 2, r[0] >= 0, r[1] >= 0, r[0] <= (resultText as NSString).length,
                              r[1] <= (resultText as NSString).length - r[0],
                              Range(NSRange(location: r[0], length: r[1]), in: resultText) != nil else { throw EditorFailure.invalidEdit("Plugin returned invalid UTF-16 selection.") }
                        return NSRange(location: r[0], length: r[1])
                    }
                    completion(.success(TextEditResult(text: resultText, selections: nsRanges)))
                } catch { completion(.failure(error)) }
            }
        } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        return runner
    }
}
