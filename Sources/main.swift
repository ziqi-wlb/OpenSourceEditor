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
if arguments.contains("--ui-self-test") { setbuf(stdout, nil) }
if arguments.contains("--self-test") {
    exit(CoreTestRunner.run())
}

if arguments.contains("--preferences-test") { exit(PreferencesTestRunner.run()) }
if arguments.contains("--document-settings-test") { exit(DocumentSettingsTestRunner.run()) }
if let flag = arguments.firstIndex(of: "--contract-test"), flag + 1 < arguments.count {
    exit(ContractTestRunner.run(path: arguments[flag + 1]))
}
if arguments.contains("--benchmark") { exit(BenchmarkRunner.run()) }
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = EditorAppDelegate(recentFiles: RecentFiles(defaults: arguments.contains("--ui-self-test") ? nil : .standard))
application.delegate = delegate
if arguments.contains("--service-test") {
    application.setActivationPolicy(.prohibited)
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in exit(ServiceTestRunner.run()) }
    application.run()
    exit(1)
}
if let flag = arguments.firstIndex(of: "--ui-self-test"), flag + 1 < arguments.count {
    let directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        .standardizedFileURL.resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let first = directory.appendingPathComponent("first.swift")
    let second = directory.appendingPathComponent("second.txt")
    try "// first\nlet value = 1\n".write(to: first, atomically: true, encoding: .utf8)
    try "second\n".write(to: second, atomically: true, encoding: .utf8)
    delegate.start(openURLs: [first, second], projectURL: nil)
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
        Task { @MainActor in exit(await UITestRunner.run(delegate: delegate, directory: directory)) }
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
delegate.start(openURLs: openURLs, projectURL: projectURL)
application.run()
