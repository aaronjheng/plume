import AppKit
import SwiftUI

/// Font descriptor for the editor's AppKit surfaces (text views) and the
/// SwiftUI placeholder overlay, as a single per-editor option.
///
/// Unlike the old global `EditorTheme` size tokens, this is a value: the
/// host chooses font size/weight/mono directly per editor (Monaco's
/// `editor.fontSize` shape). `size` is explicit on every instance, so
/// two editors in one process can read at different sizes without
/// touching any global. Preset statics keep the familiar names callable
/// and overridable at construction; `custom` builds any other point size.
public struct EditorFont: Equatable, Sendable, Hashable {
    /// Point size (12 for caption/small slots, 13 for body slots).
    public let size: CGFloat
    /// SF weight (`.regular` for the mono family and proportional text).
    public let weight: NSFont.Weight
    /// Whether this slot renders in the monospaced face (SF Mono) or the
    /// proportional system face.
    public let monospaced: Bool

    public init(size: CGFloat, weight: NSFont.Weight = .regular, monospaced: Bool) {
        self.size = size
        self.weight = weight
        self.monospaced = monospaced
    }

    /// Proportional system text at 12pt.
    public static let systemSubheadline = EditorFont(size: 12, monospaced: false)
    /// Monospaced 12pt (default for the multi-line editor).
    public static let monoSubheadline = EditorFont(size: 12, monospaced: true)
    /// Monospaced 13pt (the body slot: response bodies, wider panes).
    public static let monoBody = EditorFont(size: 13, monospaced: true)
    /// Monospaced 12pt tight single-line surfaces (the URL bar).
    public static let monoURLBar = EditorFont(size: 12, monospaced: true)
    /// Monospaced 11pt microcopy (captions, metadata).
    public static let monoCaption = EditorFont(size: 11, monospaced: true)

    /// Any other point size against the regular-weight mono/proportional
    /// faces; hosts reaching for a bespoke size call this instead of
    /// mutating a global token.
    public static func custom(size: CGFloat, monospaced: Bool = true, weight: NSFont.Weight = .regular) -> EditorFont {
        EditorFont(size: size, weight: weight, monospaced: monospaced)
    }

    public var swiftUIFont: Font {
        // Mono faces route through the same SF Mono any AppKit surface
        // gets from `nsFont`; bit-for-bit the same point size. The
        // weights come from a fixed table so SwiftUI never has to read
        // a global at render time.
        guard monospaced else { return Font.system(size: size, weight: swiftWeight) }
        return Font.system(size: size, weight: swiftWeight, design: .monospaced)
    }

    /// The `Font.Weight` counterpart of `weight`, resolved through a
    /// plain switch — `Font.Weight` has no raw-value initialiser.
    private var swiftWeight: Font.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    /// The AppKit face as stocked (never metrics-remapped): the balanced
    /// font exists only inside the coordinator's text font. Host
    /// surfaces (URL bars, fields) read this directly — stock metrics
    /// is exactly what they want.
    public var nsFont: NSFont {
        monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
    }
}
