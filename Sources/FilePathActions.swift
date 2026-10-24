import Foundation

/// Text representations of a local path; lookup URLs never come from menu labels.
enum FilePathFormat {
    case absolute, relative, filename, directory

    func string(for url: URL?, project: URL?) -> String? {
        guard let url, url.isFileURL else { return nil }
        let file = url.standardizedFileURL
        switch self {
        case .absolute: return file.path
        case .filename: return file.lastPathComponent
        case .directory: return file.deletingLastPathComponent().path
        case .relative:
            guard let project, project.isFileURL else { return nil }
            let root = project.standardizedFileURL.pathComponents
            let components = file.pathComponents
            guard components.count >= root.count, Array(components.prefix(root.count)) == root else { return nil }
            let suffix = components.dropFirst(root.count)
            return suffix.isEmpty ? "." : suffix.joined(separator: "/")
        }
    }
}
