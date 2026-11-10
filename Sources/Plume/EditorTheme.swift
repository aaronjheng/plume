import AppKit
import SwiftUI

/// Plume's chrome seam: the ONLY place the editor files (`Editor*`,
/// `SyntaxHighlight`, `EditorFont`, `EditorButtons`) read the host's theme.
/// Every token is a settable static with a neutral system default; a host
/// assigns its own values once at app launch (before any editor renders)
/// and never touches them again. The tokens are dynamic colors throughout,
/// so light/dark switching keeps working after the one-time install.
///
/// Keep the set closed: a token missing from this list is a boundary
/// violation, not a reason to reach for the host's theme types directly.
public enum EditorTheme {
    // MARK: Semantic colors

    nonisolated(unsafe) public static var accent: Color = .accentColor
    nonisolated(unsafe) public static var success: Color = .green
    nonisolated(unsafe) public static var error: Color = .red
    nonisolated(unsafe) public static var warning: Color = .orange
    nonisolated(unsafe) public static var textPrimary: Color = .primary
    nonisolated(unsafe) public static var textSecondary: Color = .secondary
    nonisolated(unsafe) public static var tertiaryText: Color = Color(nsColor: .tertiaryLabelColor)
    nonisolated(unsafe) public static var border: Color = .primary.opacity(0.15)
    nonisolated(unsafe) public static var borderStrong: Color = .primary.opacity(0.20)
    nonisolated(unsafe) public static var destructiveBorder: Color = .red.opacity(0.55)
    nonisolated(unsafe) public static var controlBackground: Color = Color(nsColor: .controlBackgroundColor)
    nonisolated(unsafe) public static var fieldBackground: Color = .primary.opacity(0.03)
    nonisolated(unsafe) public static var subtleBackground: Color = .secondary.opacity(0.10)
    nonisolated(unsafe) public static var tabHoverBackground: Color = .primary.opacity(0.05)
    nonisolated(unsafe) public static var tabActiveBackground: Color = .primary.opacity(0.08)
    nonisolated(unsafe) public static var popupShadow: Color = .primary.opacity(0.22)

    // MARK: AppKit fills (the text view and gutter draw through NSColor)

    nonisolated(unsafe) public static var textPrimaryNS: NSColor = .labelColor
    nonisolated(unsafe) public static var codeBackgroundNS: NSColor = .textBackgroundColor
    /// Current-line highlight wash (the band behind the caret's line),
    /// following the pattern of Monaco's `editor.lineHighlightBackground`:
    /// Monaco's default is NO fill (a transparent line with just the
    /// border), so the default here is clear too; hosts install a wash if
    /// they want one.
    nonisolated(unsafe) public static var lineHighlightBackgroundNS: NSColor = .clear
    /// Current-line highlight border (Monaco's `editor.lineHighlightBorder`):
    /// Monaco's default themes use a barely-offset gray (#282828 on
    /// #1E1E1E dark, #eeeeee on #ffffff light) — ~7% label over the
    /// background. Hosts install their own value.
    nonisolated(unsafe) public static var lineHighlightBorderNS: NSColor =
        .labelColor.withAlphaComponent(0.07)
    /// Overview-ruler slider thumb (Monaco's `scrollbarSlider.background`):
    /// dark #797979 @ 40% / light #646464 @ 40%. Hosts install their own.
    nonisolated(unsafe) public static var scrollbarSliderNS: NSColor = NSColor(
        name: nil
    ) { appearance in
        let dark =
            appearance.bestMatch(from: [
                .darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastVibrantDark,
            ]) != nil
        return NSColor(
            calibratedWhite: dark ? 121.0 / 255 : 100.0 / 255, alpha: 0.4)
    }
    /// Overview-ruler border (Monaco's `editorOverviewRuler.border`):
    /// 30% gray (#7f7f7f4d) in every appearance. Hosts install their own.
    nonisolated(unsafe) public static var overviewRulerBorderNS: NSColor =
        NSColor(calibratedWhite: 127.0 / 255, alpha: 0.3)
    /// Selection wash. Nil keeps the system selection color (Plume's
    /// historic behavior); hosts set it to tint selections Monaco-style
    /// (`editor.selectionBackground`). Set once at app launch.
    nonisolated(unsafe) public static var selectionBackgroundNS: NSColor?
    /// Insertion-point color. Nil keeps the accent color; hosts set it to
    /// decouple the caret from the accent (Monaco's `editorCursor.foreground`).
    nonisolated(unsafe) public static var insertionPointColorNS: NSColor?

    // MARK: Syntax colors (the paint walks)

    nonisolated(unsafe) public static var syntaxKey: Color = .accentColor
    nonisolated(unsafe) public static var syntaxString: Color = .red
    nonisolated(unsafe) public static var syntaxNumber: Color = .purple
    nonisolated(unsafe) public static var syntaxKeyword: Color = .pink
    nonisolated(unsafe) public static var syntaxPlain: Color = .secondary
    /// Comment token (Monaco `comment`). Nil aliases `syntaxPlain`, so
    /// hosts that have not installed it keep the historic comment color.
    nonisolated(unsafe) public static var syntaxComment: Color?
    /// Function-name token (call callees, Lua `function_name`/`method`).
    /// Nil aliases `syntaxKey`, so existing guest palettes are unchanged.
    nonisolated(unsafe) public static var syntaxFunction: Color?
    /// Variable token (Lua identifiers, Bash names). Nil aliases
    /// `syntaxKey`, so existing guest palettes are unchanged.
    nonisolated(unsafe) public static var syntaxVariable: Color?
    /// Constant token (`true`/`false`/`null`/`nil`/`undefined`). Nil
    /// aliases `syntaxKeyword`, so existing guest palettes are unchanged.
    nonisolated(unsafe) public static var syntaxConstant: Color?

    // MARK: Fonts (SwiftUI side; `EditorFont` derives the NSFont pair)

    nonisolated(unsafe) public static var fontSmall: Font = .system(size: 12)
    nonisolated(unsafe) public static var fontMonoSubheadline: Font = .system(size: 12, design: .monospaced)
    nonisolated(unsafe) public static var fontMonoBody: Font = .system(size: 13, design: .monospaced)
    nonisolated(unsafe) public static var fontMonoURLBar: Font = .system(size: 12, design: .monospaced)
    nonisolated(unsafe) public static var fontMonoCaption: Font = .system(size: 11, design: .monospaced)
    nonisolated(unsafe) public static var fontIconCompact: Font = .system(size: 12)

    // MARK: Metrics

    nonisolated(unsafe) public static var spaceXSmall: CGFloat = 4
    nonisolated(unsafe) public static var spaceSmall: CGFloat = 8
    nonisolated(unsafe) public static var spaceCompact: CGFloat = 6
    nonisolated(unsafe) public static var spaceMedium: CGFloat = 12
    nonisolated(unsafe) public static var radiusSmall: CGFloat = 6
    nonisolated(unsafe) public static var radiusMedium: CGFloat = 8
    nonisolated(unsafe) public static var lineField: CGFloat = 1
    nonisolated(unsafe) public static var lineFocusedField: CGFloat = 2
    /// Width of the current-line highlight border (`lineHighlightBorderNS`),
    /// matching Monaco's 2px line-highlight border by default (1px only
    /// for high-contrast themes there).
    nonisolated(unsafe) public static var lineHighlightBorderWidth: CGFloat = 2
    /// Text line-height multiplier, applied through the paragraph style's
    /// `lineHeightMultiple` (1 = the font's natural leading; hosts pick a
    /// larger value for airier code lines, Monaco-style).
    nonisolated(unsafe) public static var lineHeightMultiple: CGFloat = 1
    nonisolated(unsafe) public static var toggleControlSize: CGFloat = 26
    nonisolated(unsafe) public static var opacityDisabled: Double = 0.45
    nonisolated(unsafe) public static var motionQuick: Animation = .easeOut(duration: 0.12)
    /// Diagnostic: when true, EditorTextView skips all custom draw work
    /// (line band, indent guides, whitespace) and renders text only.
    nonisolated(unsafe) public static var debugDisableCustomDrawing = false
}
