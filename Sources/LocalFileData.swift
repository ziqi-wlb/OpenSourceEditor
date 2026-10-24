import Foundation

enum LocalFileData {
    /// The read itself is bounded, even if a file grows after metadata inspection.
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw EditorFailure.invalidEdit("File exceeds the \(maximumBytes)-byte read limit.") }
        return data
    }
}
