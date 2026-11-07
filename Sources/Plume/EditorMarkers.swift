import AppKit
import SwiftUI

/// Severity of a host-injected marker. The raw values (hint = 1, info = 2,
/// warning = 4, error = 8) follow the common editor severity scale, so a
/// host bridging external diagnostics can pass them through untouched.
public enum EditorMarkerSeverity: Int, Comparable, Sendable {
    case hint = 1
    case info = 2
    case warning = 4
    case error = 8

    /// Paint color for squiggles and gutter dots.
    var color: Color {
        switch self {
        case .error: EditorTheme.error
        case .warning: EditorTheme.warning
        case .info, .hint: EditorTheme.accent
        }
    }

    var nsColor: NSColor { NSColor(color) }

    /// Lower raw value = less severe (gutter dots show the worst per line).
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One host-injected diagnostic, simplified to the fields an embedded
/// editor renders: a range, a
/// severity, and a message. Hosts compute ranges against the same text the
/// editor holds (UTF-16, like `annotations`); markers re-read on every
/// host update, so stale ranges after edits correct themselves on the next
/// render.
public struct EditorMarker: Equatable, Sendable {
    public let severity: EditorMarkerSeverity
    /// UTF-16 range the squiggle covers, clamped to the document.
    public let range: NSRange
    public let message: String

    public init(severity: EditorMarkerSeverity, range: NSRange, message: String) {
        self.severity = severity
        self.range = range
        self.message = message
    }
}

/// One rendered diagnostic: a host marker or a tree-sitter syntax error,
/// already clamped and capped - the shared shape the squiggle pass, the
/// gutter, and the tooltips read.
struct DiagnosticEntry {
    let range: NSRange
    let message: String
    let severity: EditorMarkerSeverity
}
