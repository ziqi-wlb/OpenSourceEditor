import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--version") {
    print("Source Editor " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"))
    exit(0)
}
if arguments.contains("--help") {
    print("Usage: source-editor [--project FOLDER] [FILE ...]\nOptions: --help, --version")
    exit(0)
}
#if EDITOR_TESTS
if let flag = arguments.first(where: { $0.hasPrefix("--recovery-measure=") }) {
    exit(RecoveryPerformanceTests.run(units: Int(flag.dropFirst("--recovery-measure=".count)) ?? 0))
}
if let flag = arguments.first(where: { $0.hasPrefix("--recovery-abrupt-write=") }) {
    ProductFeatureTests.writeAbruptRecovery(directory: URL(fileURLWithPath: String(flag.dropFirst("--recovery-abrupt-write=".count)), isDirectory: true))
}
if let flag = arguments.first(where: { $0.hasPrefix("--recovery-read=") }) {
    exit(ProductFeatureTests.readAbruptRecovery(URL(fileURLWithPath: String(flag.dropFirst("--recovery-read=".count)))))
}
if arguments.contains("--ui-self-test") || arguments.contains("--multi-window-ui-test") { setbuf(stdout, nil) }
if arguments.contains("--self-test") {
    exit(CoreTestRunner.run())
}

if arguments.contains("--preferences-test") { exit(PreferencesTestRunner.run()) }
if arguments.contains("--document-settings-test") { exit(DocumentSettingsTestRunner.run()) }
if arguments.contains("--product-features-test") { exit(ProductFeatureTests.run()) }
if arguments.contains("--daily-features-test") { exit(DailyFeatureTests.run()) }
if let flag = arguments.firstIndex(of: "--contract-test"), flag + 1 < arguments.count {
    exit(ContractTestRunner.run(path: arguments[flag + 1]))
}
if arguments.contains("--benchmark") { exit(BenchmarkRunner.run()) }
let application = NSApplication.shared
application.setActivationPolicy(.regular)
if let flag = arguments.first(where: { $0.hasPrefix("--draft-restart-write=") || $0.hasPrefix("--draft-restart-read=") || $0.hasPrefix("--draft-ui-test=") }) {
    setbuf(stdout, nil)
    let directory = URL(fileURLWithPath: String(flag.split(separator: "=", maxSplits: 1)[1]), isDirectory: true)
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
        Task { @MainActor in
            if flag.hasPrefix("--draft-restart-write=") {
                do { try DraftRecoveryUITests.prepareNormalQuit(directory: directory) }
                catch { fputs(error.localizedDescription, stderr); exit(1) }
            } else if flag.hasPrefix("--draft-restart-read=") { exit(await DraftRecoveryUITests.readNormalRestart(directory: directory)) }
            else { exit(await DraftRecoveryUITests.run(directory: directory)) }
        }
    }
    application.run()
    exit(0)
}
let delegate = EditorAppDelegate(recentFiles: RecentFiles(defaults: (arguments.contains("--ui-self-test") || arguments.contains("--multi-window-ui-test") || arguments.contains("--performance-test") || arguments.contains("--product-ui-test") || arguments.contains("--daily-ui-test")) ? nil : .standard))
application.delegate = delegate
if arguments.contains("--daily-ui-test") {
    setbuf(stdout, nil)
    let path = arguments.first(where: { $0.hasPrefix("--daily-directory=") }).map { String($0.dropFirst("--daily-directory=".count)) } ?? ".build/daily-ui"
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
        Task { @MainActor in exit(await DailyUITests.run(directory: URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath())) }
    }
    application.run()
    exit(1)
}
if arguments.contains("--product-ui-test") {
    setbuf(stdout, nil)
    let path = arguments.first(where: { $0.hasPrefix("--product-directory=") }).map { String($0.dropFirst("--product-directory=".count)) } ?? ""
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
        Task { @MainActor in
            let result = await ProductUITests.run(app: delegate, directory: URL(fileURLWithPath: path, isDirectory: true))
            exit(result.failed == 0 ? 0 : 1)
        }
    }
    application.run()
    exit(1)
}
if arguments.contains("--performance-test") {
    setbuf(stdout, nil)
    func option(_ name: String) -> String { arguments.first(where: { $0.hasPrefix(name + "=") }).map { String($0.dropFirst(name.count + 1)) } ?? "" }
    let directory = URL(fileURLWithPath: option("--performance-directory"), isDirectory: true)
    let scenario = option("--performance-scenario")
    let bytes = Int(option("--performance-bytes")) ?? 65536
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
        Task { @MainActor in exit(await PerformanceTests.run(app: delegate, directory: directory, scenario: scenario, bytes: bytes)) }
    }
    application.run()
    exit(1)
}
if arguments.contains("--service-test") {
    application.setActivationPolicy(.prohibited)
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in exit(ServiceTestRunner.run()) }
    application.run()
    exit(1)
}
if arguments.contains("--multi-window-quit-test") {
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in _ = MultiWindowQuitTests(app: delegate) }
    application.run()
    exit(0)
}
if let flag = arguments.firstIndex(where: { $0 == "--ui-self-test" || $0 == "--multi-window-ui-test" }), flag + 1 < arguments.count {
    let directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        .standardizedFileURL.resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let first = directory.appendingPathComponent("first.swift")
    let second = directory.appendingPathComponent("second.txt")
    try "// first\nlet value = 1\n".write(to: first, atomically: true, encoding: .utf8)
    try "second\n".write(to: second, atomically: true, encoding: .utf8)
    let workspace = delegate.newWindow(openURLs: [first, second], projectURL: nil)
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
        Task { @MainActor in
            if arguments[flag] == "--multi-window-ui-test" {
                let result = await MultiWindowUITests.run(delegate: workspace, directory: directory)
                exit(result.failed == 0 ? 0 : 1)
            }
            exit(await UITestRunner.run(delegate: workspace, directory: directory))
        }
    }
    application.run()
    exit(1)
}
#endif
#if !EDITOR_TESTS
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = EditorAppDelegate()
application.delegate = delegate
#endif
var openURLs: [URL] = []
var projectURL: URL?
var index = 0
while index < arguments.count {
    if arguments[index] == "--project" && index + 1 < arguments.count {
        index += 1
        projectURL = URL(fileURLWithPath: arguments[index], isDirectory: true)
    } else if !arguments[index].hasPrefix("--") {
        openURLs.append(URL(fileURLWithPath: arguments[index]))
    }
    index += 1
}
if forwardToRunningEditor(openURLs: openURLs, projectURL: projectURL) { exit(0) }
delegate.launch(openURLs: openURLs, projectURL: projectURL)
application.run()
