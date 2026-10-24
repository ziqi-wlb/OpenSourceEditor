import AppKit

enum EditorTheme {
    static var isLight = false
    static var background: NSColor { isLight ? NSColor(calibratedWhite: 0.98, alpha: 1) : NSColor(calibratedRed: 0.075, green: 0.085, blue: 0.11, alpha: 1) }
    static var panel: NSColor { isLight ? NSColor(calibratedWhite: 0.92, alpha: 1) : NSColor(calibratedRed: 0.105, green: 0.12, blue: 0.15, alpha: 1) }
    static var foreground: NSColor { isLight ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedRed: 0.86, green: 0.89, blue: 0.94, alpha: 1) }
    static var muted: NSColor { isLight ? NSColor(calibratedWhite: 0.38, alpha: 1) : NSColor(calibratedRed: 0.60, green: 0.66, blue: 0.75, alpha: 1) }
    static let accent = NSColor(calibratedRed: 0.40, green: 0.70, blue: 1, alpha: 1)
    static let font = NSFont(name: "Menlo", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
}
