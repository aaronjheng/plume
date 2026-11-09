import AppKit
import SwiftTreeSitter

/// A syntax the generic editor can highlight and comment: a tree-sitter
/// grammar plus its paint walk. The package is host-neutral by design - it
/// ships NO grammars and NO presets. Every language (json, xml, javascript,
/// bash, lua, ...) is a host-side `SyntaxProfile` built around the package's
/// `SyntaxHighlight` walks (or the host's own). Equatable by `id`: two
/// profiles with the same id are the same syntax (the editor diffs profiles
/// to decide on full re-styles).
public struct SyntaxProfile: Equatable, Sendable {
    /// One auto-pair: the opening and closing characters (quotes pair a
    /// character with itself, e.g. `"`).
    public struct BracketPair: Equatable, Sendable {
        public let open: Character
        public let close: Character
        public init(open: Character, close: Character) {
            self.open = open
            self.close = close
        }
    }

    /// Whether typed openers auto-insert their closer (Monaco
    /// `autoClosingBrackets`). The default `.languageDefined` closes
    /// only the pairs listed in `brackets`.
    public enum AutoClosingMode: Equatable, Sendable {
        case languageDefined
        case always
        case never
    }

    /// Whether typing an opener with a selection wraps the selection
    /// (Monaco `autoSurround`). The default `.languageDefined` wraps in
    /// any pair listed in `brackets`.
    public enum AutoSurroundMode: Equatable, Sendable {
        case languageDefined
        case quotes
        case brackets
        case never
    }

    /// One enter rule (Monaco `onEnterRules`): when `pattern` matches the
    /// line text before the caret, the new line indents by `action`
    /// relative to the carried indent. Only the first match applies.
    public struct OnEnterRule: Equatable, Sendable {
        /// Indent delta for the new line.
        public enum IndentAction: Equatable, Sendable {
            /// One unit deeper.
            case indent
            /// One unit shallower.
            case outdent
            /// No change (stops rule evaluation for the line).
            case none
        }

        /// Regular expression matched against the current line's prefix
        /// (line start through the caret).
        public let pattern: String
        public let action: IndentAction
        public init(pattern: String, action: IndentAction) {
            self.pattern = pattern
            self.action = action
        }
    }

    /// How ⌘/ comments the language.
    public enum CommentStyle: Equatable, Sendable {
        /// The grammar has no comments (JSON): the key falls through.
        case none
        /// Line comments: `prefix` (with its trailing space) is inserted
        /// after the line's indent, e.g. `"// "` for JavaScript.
        case line(prefix: String)
        /// Block comments wrapped around the selection, e.g.
        /// `open: "<!--", close: "-->"` for XML.
        case block(open: String, close: String)
    }

    public let id: String
    /// Loads the tree-sitter language; nil (or a failed load) degrades the
    /// editor to annotation-only for this profile.
    public let language: @Sendable () -> Language?
    /// Walks a parsed tree into (range, color) runs. Receives the root node
    /// and the document's UTF-16 length; must append runs in order.
    public let paint: @Sendable (_ root: Node, _ length: Int, _ cursor: inout Int, _ runs: inout [(NSRange, NSColor)]) -> Void
    public let commentStyle: CommentStyle
    /// Per-language auto-pairs consulted by smart insertion (typing an
    /// opener inserts/skip-over wraps the selection). `{` is deliberately
    /// absent from the default set: in an API client every brace is either
    /// a JSON delimiter or the `{{template}}` opener, and pairing it eats
    /// the `{{` sequence the completion popup needs to trigger.
    public let brackets: [BracketPair]
    /// Auto-closing behaviour for this language.
    public let autoClosing: AutoClosingMode
    /// Surrounding behaviour for this language.
    public let autoSurround: AutoSurroundMode
    /// Enter rules (see `OnEnterRule`), evaluated first-match after the
    /// opener expansion. Empty keeps the historic carry-only indent.
    public let onEnterRules: [OnEnterRule]
    /// Whether Return inside a line comment starts the next line with the
    /// comment prefix (Monaco comment continuation). Off by default;
    /// bundled line-comment profiles opt in.
    public let continueLineComments: Bool

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    /// The historic global set: `()`, `[]` and the three quotes.
    public static var defaultBrackets: [BracketPair] {
        [
            BracketPair(open: "(", close: ")"),
            BracketPair(open: "[", close: "]"),
            BracketPair(open: "\"", close: "\""),
            BracketPair(open: "'", close: "'"),
            BracketPair(open: "`", close: "`"),
        ]
    }

    /// Creates a profile. Hosts add languages by constructing one of
    /// these around their own grammar + paint walk.
    public init(
        id: String,
        language: @escaping @Sendable () -> Language?,
        paint: @escaping @Sendable (_ root: Node, _ length: Int, _ cursor: inout Int, _ runs: inout [(NSRange, NSColor)]) -> Void,
        commentStyle: CommentStyle,
        brackets: [BracketPair] = SyntaxProfile.defaultBrackets,
        autoClosing: AutoClosingMode = .languageDefined,
        autoSurround: AutoSurroundMode = .languageDefined,
        onEnterRules: [OnEnterRule] = [],
        continueLineComments: Bool = false
    ) {
        self.id = id
        self.language = language
        self.paint = paint
        self.commentStyle = commentStyle
        self.brackets = brackets
        self.autoClosing = autoClosing
        self.autoSurround = autoSurround
        self.onEnterRules = onEnterRules
        self.continueLineComments = continueLineComments
    }

    /// The zero-syntax profile: no grammar, no paint, no comments. The
    /// editor's default; hosts that need annotation-only surfaces reuse it.
    public static var plain: SyntaxProfile {
        SyntaxProfile(
            id: "plain",
            language: { nil },
            paint: { _, _, _, _ in },
            commentStyle: .none)
    }
}
