import Foundation
import CoreServices
import CryptoKit

// One recursive event stream per workspace, including external open files.
// FSEvents coalesces changes; no timer scans or polls file contents.
final class EditorFileMonitor {
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var changed = Set<String>()
    private let roots: [String]
    private let onChange: ([URL]) -> Void
    init(paths: [URL], onChange: @escaping ([URL]) -> Void) {
        self.onChange = onChange
        let ordered = Set(paths.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }).sorted { $0.count < $1.count }
        var filtered: [String] = []
        for path in ordered where !filtered.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { filtered.append(path) }
        roots = filtered
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let owner = Unmanaged<EditorFileMonitor>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            for i in 0..<min(count, 256) { if let path = array[i] as? String { owner.changed.insert(path) } }
            let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            if count > 256 || owner.changed.count > 1024 || (0..<count).contains(where: { flags[$0] & rescan != 0 }) { owner.changed = Set(owner.roots) }
            owner.schedule()
        }, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream { FSEventStreamSetDispatchQueue(stream, DispatchQueue.main); if !FSEventStreamStart(stream) { stop() } }
    }
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let urls = changed.map { URL(fileURLWithPath: $0) }
            changed.removeAll(); pending = nil
            onChange(urls)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    func stop() {
        pending?.cancel(); pending = nil; changed.removeAll()
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil
    }
    deinit { stop() }
}

enum DiskCheckResult {
    case unchanged, missing, changed(text: String, encoding: EditorEncoding, digest: Data), unavailable(String)
}
final class DiskCheckOperation: Operation {
    let url: URL
    let digest: String?
    let encoding: EditorEncoding
    var result: DiskCheckResult = .unchanged
    init(url: URL, digest: String?, encoding: EditorEncoding) { self.url = url; self.digest = digest; self.encoding = encoding }
    override func main() {
        guard !isCancelled else { return }
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { result = .missing; return }
            let data = try LocalFileData.read(url, maximumBytes: 32 * 1024 * 1024)
            guard !isCancelled else { return }
            let current = Data(SHA256.hash(data: data))
            if current.map({ String(format: "%02x", $0) }).joined() == digest { return }
            let (text, codec) = try EditorEncoding.decode(data, using: encoding)
            if !isCancelled { result = .changed(text: text, encoding: codec, digest: current) }
        } catch { result = .unavailable(error.localizedDescription) }
    }
}
