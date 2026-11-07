import Plume
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterLua
import TreeSitterXML

/// Preset `SyntaxProfile`s for the common embedded languages, the
/// package's "basic languages" tier: generic per-language knowledge
/// (grammar, paint walk, comment style) with every color resolved from
/// the host's `EditorTheme` at paint time. Hosts needing different
/// semantics - per-API emphasis, domain tokens - define their own
/// profiles instead; the preset is a default, not the only option.
extension SyntaxProfile {
    /// JSON: keys read in the key color, scalars in the shared token
    /// colors, no comments (the grammar has none).
    public static let json = SyntaxProfile(
        id: "json",
        language: { tree_sitter_json().map { Language($0) } },
        paint: { root, length, cursor, runs in
            SyntaxHighlight.paintJSON(run: root, asKey: false, length: length, cursor: &cursor, runs: &runs)
        },
        commentStyle: .none)

    /// XML: element names as keywords, attribute names as keys,
    /// attribute values as strings, block `<!-- -->` comments.
    public static let xml = SyntaxProfile(
        id: "xml",
        language: { tree_sitter_xml().map { Language($0) } },
        paint: { root, length, cursor, runs in
            SyntaxHighlight.paintXML(run: root, length: length, cursor: &cursor, runs: &runs)
        },
        commentStyle: .block(open: "<!--", close: "-->"))

    /// JavaScript: strings/numbers/comments in the shared token colors,
    /// keyword tokens, and the callee side of every call
    /// (`client.test(...)`) emphasized as one function-name chain.
    public static let javascript = SyntaxProfile(
        id: "javascript",
        language: { tree_sitter_javascript().map { Language($0) } },
        paint: { root, length, cursor, runs in
            SyntaxHighlight.paintJS(run: root, length: length, cursor: &cursor, runs: &runs)
        },
        commentStyle: .line(prefix: "// "))

    /// Shell: pipes and redirects stay plain, flags/keywords take the
    /// keyword color, strings and numbers the shared token colors,
    /// variables the key color. `#` line comments.
    public static let bash = SyntaxProfile(
        id: "bash",
        language: { tree_sitter_bash().map { Language($0) } },
        paint: { root, length, cursor, runs in
            LanguagePaints.bash(node: root, length: length, cursor: &cursor, runs: &runs)
        },
        commentStyle: .line(prefix: "# "))

    /// Lua: keywords and literals, strings/numbers/comments in the
    /// shared token colors, identifiers and member chains as one
    /// key-colored surface. `--` line comments.
    public static let lua = SyntaxProfile(
        id: "lua",
        language: { tree_sitter_lua().map { Language($0) } },
        paint: { root, length, cursor, runs in
            LanguagePaints.lua(node: root, length: length, cursor: &cursor, runs: &runs)
        },
        commentStyle: .line(prefix: "-- "))
}
