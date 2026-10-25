import Foundation

/// Owns bounded, canonical MRU identities for separately stored files and folders.
final class RecentLocations {
    enum Kind {
        case files, folders
        var storageKey: String {
            switch self {
            case .files: return "sourceEditor.recentFilePaths"
            case .folders: return "sourceEditor.recentFolderPaths"
            }
        }
    }
    private let defaults: UserDefaults?
    private let key: String
    private let limit = 20
    private(set) var urls: [URL] = []

    init(defaults: UserDefaults? = .standard, kind: Kind = .files) {
        self.defaults = defaults
        self.key = kind.storageKey
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
