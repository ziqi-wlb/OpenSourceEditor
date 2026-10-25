import AppKit

/// Runs in its own test process so real NSApplication termination can complete.
final class MultiWindowQuitTests {
    private let app: EditorAppDelegate
    private let first: EditorWorkspace
    private let second: EditorWorkspace
    private var requested = false
    private var observedFreeze = false
    private var observedMixedCompletion = false
    private var timedOut = false
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private let deadline = Date().addingTimeInterval(10)
    private let readyFile = FileManager.default.temporaryDirectory.appendingPathComponent("source-editor-quit-ready-\(UUID().uuidString)")

    init(app: EditorAppDelegate) {
        self.app = app
        first = app.newWindow(tabbed: false)
        second = app.newWindow(tabbed: false)
        _ = first.executeCommand("new_file")
        _ = second.executeCommand("new_file")
        first.runBuild(spec: BuildSpec(argv: ["/bin/sleep", "30"], timeoutSeconds: 35))
        second.runBuild(spec: BuildSpec(argv: ["/usr/bin/python3", "-u", "-c",
            "import pathlib,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); pathlib.Path(sys.argv[1]).write_text('READY'); time.sleep(30)", readyFile.path], timeoutSeconds: 35))
        observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: NSApp, queue: .main) { [self] _ in
            let checks = [observedFreeze && !timedOut, observedMixedCompletion, !first.hasRunningWork && !second.hasRunningWork]
            let result: [String: Any] = ["passed": checks.filter { $0 }.count, "failed": checks.filter { !$0 }.count,
                "all_windows_frozen": observedFreeze, "waited_after_first_worker_finished": observedMixedCompletion,
                "all_workers_finished_before_termination": checks[2]]
            let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            try? FileManager.default.removeItem(at: readyFile)
            timer?.invalidate()
        }
        timer = Timer(timeInterval: 0.02, repeats: true) { [self] _ in
            if Date() > deadline && !timedOut {
                timedOut = true
                fputs("Multi-window termination timed out; cancelling owned fixtures.\n", stderr)
                _ = first.executeCommand("cancel_build")
                _ = second.executeCommand("cancel_build")
            }
            if timedOut {
                if !first.hasRunningWork && !second.hasRunningWork {
                    try? FileManager.default.removeItem(at: readyFile)
                    print("{\"passed\":0,\"failed\":1,\"error\":\"termination timed out\"}")
                    exit(1)
                }
                return
            }
            if requested {
                observedFreeze = observedFreeze || (first.currentTextView?.isEditable == false && second.currentTextView?.isEditable == false)
                if !first.hasRunningWork && second.hasRunningWork { observedMixedCompletion = app.workspaces.count == 2 }
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
        RunLoop.main.add(timer!, forMode: .modalPanel)
        // terminate() enters a modal wait for .terminateLater. Observe that wait
        // from a different timer, since a firing timer cannot reenter itself.
        let requestTimer = Timer(timeInterval: 0.02, repeats: true) { [self] value in
            guard !timedOut, FileManager.default.fileExists(atPath: readyFile.path) else { return }
            value.invalidate()
            requested = true
            NSApp.terminate(nil)
        }
        RunLoop.main.add(requestTimer, forMode: .common)
    }
}
