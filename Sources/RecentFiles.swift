import Foundation

/// Stores successful file opens/saves; paths remain lookup values, never labels.
final class RecentFiles {
    private let defaults: UserDefaults?
    private let key = "sourceEditor.recentFilePaths"
    private let limit = 20
    private(set) var urls: [URL] = []

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        for path in (defaults?.stringArray(forKey: key) ?? []).reversed() where path.hasPrefix("/") {
            note(URL(fileURLWithPath: path), persist: false)
        }
    }

    func note(_ url: URL) { note(url, persist: true) }

    private func note(_ url: URL, persist: Bool) {
        guard url.isFileURL else { return }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        urls.removeAll { $0 == resolved }
        urls.insert(resolved, at: 0)
        if urls.count > limit { urls.removeLast(urls.count - limit) }
        if persist { save() }
    }

    func relocate(from source: URL, to destination: URL) {
        urls = urls.map { ProjectFileOperations.rebase($0, from: source, to: destination) ?? $0 }
        save()
    }

    func clear() { urls.removeAll(); save() }

    private func save() { defaults?.set(urls.map(\.path), forKey: key) }
}
