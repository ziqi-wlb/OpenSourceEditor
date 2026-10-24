import Foundation
import ImageIO

enum NoteAssets {
    static func insertImage(_ data: Data, beside document: URL) throws -> (url: URL, markdown: String) {
        guard data.count <= 16 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 16_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw EditorFailure.invalidEdit("Image paste supports at most 16 MiB input and 16 million pixels.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw EditorFailure.invalidEdit("Cannot encode the image.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw EditorFailure.invalidEdit("The image could not be encoded as PNG.") }
        guard output.length <= 4 * 1024 * 1024 else {
            throw EditorFailure.invalidEdit("The PNG image exceeds 4 MiB.")
        }
        let parent = document.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let folder = parent.appendingPathComponent("assets", isDirectory: true)
        let resolved = folder.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(parent.path + "/") else { throw EditorFailure.invalidEdit("The assets folder must stay beside this document.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let filename = "image-" + UUID().uuidString.lowercased() + ".png"
        let target = folder.appendingPathComponent(filename)
        try (output as Data).write(to: target, options: .withoutOverwriting)
        return (target, "![image](assets/\(filename))")
    }
}

enum NoteTemplate: String, CaseIterable {
    case blank, meeting, daily, tasks
    var title: String { switch self { case .blank: return "Blank Markdown Note"; case .meeting: return "Meeting Notes"; case .daily: return "Daily Notes"; case .tasks: return "Task List" } }
    func text(date: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let day = formatter.string(from: date)
        switch self {
        case .blank: return ""
        case .meeting: return "# Meeting Notes — \(day)\n\n## Agenda\n\n- \n\n## Decisions\n\n- \n\n## Action Items\n\n- [ ] \n"
        case .daily: return "# Daily Notes — \(day)\n\n## Today\n\n- [ ] \n\n## Progress\n\n- \n\n## Next Steps\n\n- [ ] \n"
        case .tasks: return "# Tasks\n\n## To Do\n\n- [ ] \n\n## Completed\n\n- [x] \n"
        }
    }
}

extension NoteEditing {
    static func wrap(_ text: String, selections: [NSRange], opening: String, closing: String) -> TextEditResult {
        guard TextOperations.valid(text, selections) else { return TextEditResult(text: text, selections: selections, error: "Invalid selection.") }
        let source = text as NSString, ordered = selections.sorted { $0.location < $1.location }
        let edits = ordered.map { TextReplacement(range: $0, text: opening + source.substring(with: $0) + closing) }
        let result = TextOperations.apply(in: text, edits: edits)
        guard result.error == nil else { return result }
        let added = opening.utf16.count + closing.utf16.count
        return TextEditResult(text: result.text, selections: ordered.enumerated().map { index, range in
            NSRange(location: range.location + index * added + opening.utf16.count, length: range.length)
        })
    }
}
