import AppKit
import Darwin

enum ServiceTestRunner {
    private struct BuildObservation {
        var output = ""
        var code: Int32?
        var callbacks = 0
        var startupError: String?
        var sawReady = false
        var readySource = "not requested"
        var stillRunning = false
        var logPath = ""
        var json: [String: Any] {
            ["output": output, "exit_code": code.map { NSNumber(value: $0) as Any } ?? NSNull(),
             "completion_calls": callbacks, "startup_error": startupError ?? "",
             "saw_ready": sawReady, "ready_source": readySource, "is_running_after": stillRunning, "log_path": logPath]
        }
    }

    // Call from a native Timer callback, outside a DispatchQueue.main callback.
    // Blocking the main queue while awaiting its own completion cannot be tested by a semaphore.
    private static func pump(_ seconds: Double, until predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01)))
        }
        return predicate()
    }

    private static func childState(_ pid: Int32?, marker: String) -> String {
        guard let pid, pid > 0 else { return "missing_pid" }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww", "-p", String(pid), "-o", "stat=", "-o", "command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return "absent" }
            let status = text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            if status.contains("Z") { return "zombie_not_running" }
            return text.contains(marker) ? "owned_child_still_running" : "pid_identity_unknown"
        } catch { return "ps_failed: \(error)" }
    }

    private static func childPID(in output: String) -> Int32? {
        output.components(separatedBy: "\n").first(where: { $0.hasPrefix("CHILD_PID=") })
            .flatMap { Int32($0.dropFirst("CHILD_PID=".count)) }
    }

    private static func sameDirectory(_ reported: Any?, _ expected: URL) -> Bool {
        guard let path = reported as? String, path.hasPrefix("/") else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            == expected.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func run() -> Int32 {
        guard Thread.isMainThread else {
            print("{\"ok\":false,\"error\":\"ServiceTestRunner requires the main RunLoop from a Timer callback\"}")
            return 1
        }
        let started = Date()
        var rows: [[String: Any]] = []
        var retained: [BuildRunner] = []
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-editor-services-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        catch { print("{\"ok\":false,\"error\":\"cannot create owned fixture directory\"}"); return 1 }

        func record(_ id: String, _ ok: Bool, expected: Any, actual: Any) {
            rows.append(["id": id, "status": ok ? "passed" : "failed", "expected": expected, "actual": actual])
        }

        func build(_ spec: BuildSpec, document: URL? = nil, cancelAfterReady: Bool = false,
                   readyFile: URL? = nil, readyToken: String = "") -> BuildObservation {
            let runner = BuildRunner()
            retained.append(runner)
            var observation = BuildObservation()
            do {
                try runner.start(spec: spec, documentURL: document, projectURL: directory,
                    onOutput: { observation.output += $0 }, onCompletion: { code in
                        observation.code = code; observation.callbacks += 1
                    })
                if cancelAfterReady {
                    // Read the producer's readiness fact, not asynchronously delivered display output.
                    // The child writes this unique marker only after installing its SIGTERM handler.
                    func ready() -> Bool {
                        guard let readyFile, let value = try? String(contentsOf: readyFile, encoding: .utf8) else { return false }
                        return value == readyToken
                    }
                    let arrived = pump(1.5, until: { ready() || observation.code != nil }) && ready()
                    observation.sawReady = arrived
                    observation.readySource = "child fixture marker, checked before cancel after SIGTERM handler installation"
                    runner.cancel()
                }
                if !pump(3, until: { observation.code != nil }) {
                    runner.cancel()
                    _ = pump(0.8, until: { observation.code != nil })
                }
            } catch { observation.startupError = String(describing: error) }
            observation.stillRunning = runner.isRunning
            observation.logPath = runner.logURL?.path ?? ""
            return observation
        }

        let python = "/usr/bin/python3"
        let sentinel = directory.appendingPathComponent("unexpected-shell-expansion")
        let file = directory.appendingPathComponent("中文 'single' \"double\" $(touch unexpected-shell-expansion).txt")
        do {
            try Data("owned test fixture".utf8).write(to: file)
            let inspect = "import os,sys,json; print(json.dumps({'argument':sys.argv[1],'cwd':os.getcwd(),'file_env':os.environ.get('SOURCE_EDITOR_FILE')}))"
            let literal = build(BuildSpec(argv: [python, "-c", inspect, "${file}"], workingDirectory: "${project}", timeoutSeconds: 2), document: file)
            let parsed = (try? JSONSerialization.jsonObject(with: Data(literal.output.utf8))) as? [String: Any]
            record("argv_literal_path", literal.code == 0 && literal.callbacks == 1 && !literal.stillRunning
                && parsed?["argument"] as? String == file.path && sameDirectory(parsed?["cwd"], directory)
                && parsed?["file_env"] as? String == file.path && !FileManager.default.fileExists(atPath: sentinel.path),
                expected: ["argument": file.path, "cwd": directory.path, "cwd_comparison": "resolved directory identity", "sentinel_created": false], actual: literal.json)

            let shellObject: [String: Any] = ["shellCommand": "\(python) -c 'import os,json; print(json.dumps({\"file\":os.environ[\"SOURCE_EDITOR_FILE\"],\"cwd\":os.getcwd()}))'",
                "workingDirectory": "${project}", "timeoutSeconds": 2]
            let shellSpec = try JSONDecoder().decode(BuildSpec.self, from: JSONSerialization.data(withJSONObject: shellObject))
            let shell = build(shellSpec, document: file)
            let shellResult = (try? JSONSerialization.jsonObject(with: Data(shell.output.utf8))) as? [String: Any]
            record("decoded_shell_environment_path", shell.code == 0 && shell.callbacks == 1 && !shell.stillRunning
                && shellResult?["file"] as? String == file.path && sameDirectory(shellResult?["cwd"], directory)
                && !FileManager.default.fileExists(atPath: sentinel.path),
                expected: ["file": file.path, "cwd": directory.path, "cwd_comparison": "resolved directory identity", "sentinel_created": false], actual: shell.json)
        } catch { record("path_fixtures", false, expected: "valid owned argv/shell fixture", actual: String(describing: error)) }

        let chunks = "import os,time; b='😀你好'.encode(); os.write(1,b'OUT'); os.write(1,b[:1]); time.sleep(.03); os.write(1,b[1:3]); time.sleep(.03); os.write(1,b[3:]); os.write(2,'ERR尾\\n'.encode())"
        let streamed = build(BuildSpec(argv: [python, "-c", chunks], timeoutSeconds: 2))
        record("stdout_stderr_split_utf8", streamed.code == 0 && streamed.callbacks == 1 && !streamed.stillRunning
            && streamed.output == "OUT😀你好ERR尾\n", expected: "OUT😀你好ERR尾\n", actual: streamed.json)

        let cancelMarker = "REA_OWNED_CANCEL_CHILD_\(UUID().uuidString)"
        let cancelReady = directory.appendingPathComponent("cancel-child-ready.txt")
        // Keep code, filesystem identity and token as separate argv values at both process boundaries.
        // A JSON-escaped string is not a Python source literal (for example, JSON may escape '/').
        let cancelChild = "import os,pathlib,signal,sys,time; marker=sys.argv[2]; signal.signal(signal.SIGTERM,signal.SIG_IGN); pathlib.Path(sys.argv[1]).write_text(marker); os.write(1,b'READY\\n'); time.sleep(4)"
        let family = "import os,signal,subprocess,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); child=subprocess.Popen([sys.executable,'-c',sys.argv[1],sys.argv[2],sys.argv[3]]); os.write(1,('CHILD_PID='+str(child.pid)+'\\n').encode()); time.sleep(4)"
        let cancelled = build(BuildSpec(argv: [python, "-c", family, cancelChild, cancelReady.path, cancelMarker], timeoutSeconds: 3), cancelAfterReady: true,
                              readyFile: cancelReady, readyToken: cancelMarker)
        let cancelledChild = childState(childPID(in: cancelled.output), marker: cancelMarker)
        record("cancel_ignoring_term_root_and_child", cancelled.sawReady && cancelled.code == 137
            && cancelled.callbacks == 1 && !cancelled.stillRunning && cancelled.output.contains("cancelled")
            && cancelled.output.contains("READY\n")
            && ["absent", "zombie_not_running"].contains(cancelledChild),
            expected: ["exit_code": 137, "completion_calls": 1, "child": "absent or zombie, not running"],
            actual: ["build": cancelled.json, "child": cancelledChild])

        let timeout = build(BuildSpec(argv: [python, "-c", "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(4)"], timeoutSeconds: 0.2))
        record("timeout_ignoring_term", timeout.code == 137 && timeout.callbacks == 1 && !timeout.stillRunning
            && timeout.output.contains("timed out"), expected: ["exit_code": 137, "reason": "timed out"], actual: timeout.json)

        let orphanMarker = "REA_OWNED_ORPHAN_CHILD_\(UUID().uuidString)"
        let orphanCode = "import signal,sys,time; marker=sys.argv[1]; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(4)"
        let parentExit = "import os,subprocess,sys; child=subprocess.Popen([sys.executable,'-c',sys.argv[1],sys.argv[2]]); os.write(1,('CHILD_PID='+str(child.pid)+'\\n').encode()); os._exit(0)"
        let orphan = build(BuildSpec(argv: [python, "-c", parentExit, orphanCode, orphanMarker], timeoutSeconds: 2))
        let orphanState = childState(childPID(in: orphan.output), marker: orphanMarker)
        record("root_exit_cleans_inherited_pipe_child", orphan.code == 0 && orphan.callbacks == 1 && !orphan.stillRunning
            && ["absent", "zombie_not_running"].contains(orphanState),
            expected: ["exit_code": 0, "child": "absent or zombie, not running", "completion_calls": 1],
            actual: ["build": orphan.json, "child": orphanState])

        let missing = build(BuildSpec(argv: [directory.appendingPathComponent("missing-executable").path], timeoutSeconds: 1))
        record("startup_failure_final_state", missing.startupError != nil && missing.code == nil
            && missing.callbacks == 0 && !missing.stillRunning,
            expected: ["startup_error": "thrown", "completion_calls": 0, "is_running_after": false], actual: missing.json)

        func plugin(_ pluginURL: URL, command: String) -> [String: Any] {
            var result: Result<TextEditResult, Error>?
            var calls = 0
            let runner = PluginRunner.run(pythonURL: URL(fileURLWithPath: python), pluginURL: pluginURL, command: command,
                args: [:], text: "a😀b", selections: [NSRange(location: 0, length: 4)]) { value in result = value; calls += 1 }
            retained.append(runner)
            if !pump(3, until: { result != nil }) { runner.cancel(); _ = pump(0.8, until: { result != nil }) }
            var report: [String: Any] = ["completion_calls": calls, "is_running_after": runner.isRunning]
            switch result {
            case .some(.success(let edit)): report["ok"] = true; report["text"] = edit.text; report["selections"] = edit.selections.map { [$0.location, $0.length] }
            case .some(.failure(let error)): report["ok"] = false; report["error"] = String(describing: error)
            case .none: report["ok"] = false; report["error"] = "completion did not arrive within the bounded test deadline"
            }
            if let log = runner.logURL, let data = try? Data(contentsOf: log) { report["log"] = String(decoding: data.prefix(65536), as: UTF8.self) }
            return report
        }
        if let resources = Bundle.main.resourceURL {
            let success = plugin(resources.appendingPathComponent("plugin_host/demo_plugin.py"), command: "reverse_selection")
            record("bundled_plugin_success", success["ok"] as? Bool == true && success["text"] as? String == "b😀a"
                && success["selections"] as? [[Int]] == [[0, 4]] && success["completion_calls"] as? Int == 1
                && success["is_running_after"] as? Bool == false,
                expected: ["text": "b😀a", "selections": [[0, 4]], "completion_calls": 1], actual: success)
            let failureURL = directory.appendingPathComponent("owned_failure_plugin.py")
            let failureSource = "import sublime,sublime_plugin\nprint('OWNED_PLUGIN_IMPORT_NOISE')\nclass FailCommand(sublime_plugin.TextCommand):\n def run(self, edit):\n  self.view.insert(edit,0,'partial')\n  print('OWNED_PLUGIN_RUN_NOISE')\n  raise RuntimeError('OWNED_PLUGIN_EXPECTED_FAILURE')\n"
            do {
                try Data(failureSource.utf8).write(to: failureURL)
                let failure = plugin(failureURL, command: "fail")
                record("plugin_failure_stdout_isolated_no_commit", failure["ok"] as? Bool == false
                    && (failure["error"] as? String ?? "").contains("OWNED_PLUGIN_EXPECTED_FAILURE")
                    && failure["text"] == nil && failure["completion_calls"] as? Int == 1
                    && failure["is_running_after"] as? Bool == false
                    && (failure["log"] as? String ?? "").contains("OWNED_PLUGIN_IMPORT_NOISE")
                    && (failure["log"] as? String ?? "").contains("OWNED_PLUGIN_RUN_NOISE"),
                    expected: ["ok": false, "committed_result": false, "stderr_noise_in_log": true, "completion_calls": 1], actual: failure)
            } catch { record("plugin_failure_fixture", false, expected: "owned plugin written", actual: String(describing: error)) }
        } else { record("plugin_bundle_resources", false, expected: "run from built .app bundle", actual: "Bundle.main.resourceURL missing") }

        for runner in retained where runner.isRunning { runner.cancel() }
        _ = pump(0.8, until: { retained.allSatisfy { !$0.isRunning } })
        let failed = rows.filter { $0["status"] as? String == "failed" }.count
        let report: [String: Any] = ["ok": failed == 0, "tests": rows.count, "passed": rows.count - failed,
            "failed": failed, "results": rows, "elapsed_ms": Date().timeIntervalSince(started) * 1000,
            "scope": "real owned BuildRunner/PluginRunner subprocesses; no Sublime runtime execution",
            "invocation": "native Timer callback plus main RunLoop pump", "target_runtime_executed": false]
        do { print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self)) }
        catch { fputs("service test JSON encoding failed\n", stderr); return 1 }
        return failed == 0 ? 0 : 1
    }
}
