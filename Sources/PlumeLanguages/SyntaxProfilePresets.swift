import Plume
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterHTML
import TreeSitterJSON
import TreeSitterJavaScript
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
    /// colors, no comments (the grammar has none). Auto-pair table is
    /// the default set: `{` stays out because `{{variable}}` templates
    /// live inside JSON bodies. A trailing `:` indents the next line.
    public static let json = SyntaxProfile(
        id: "json",
        language: { tree_sitter_json().map { Language($0) } },
        paint: { root, length, cursor, runs in
            SyntaxHighlight.paintJSON(run: root, asKey: false, length: length, cursor: &cursor, runs: &runs)
        },
        commentStyle: .none,
        onEnterRules: [SyntaxProfile.OnEnterRule(pattern: ".*:\\s*$", action: .indent)])

    /// XML: element names as keywords, attribute names as keys,
    /// attribute values as strings, block `<!-- -->` comments.
    /// Auto-pairs `< >` on top of the default set (tags only ever open
    /// with `<`, so the extra pair cannot swallow a template token).
    public static let xml = SyntaxProfile(
        id: "xml",
        language: { tree_sitter_xml().map { Language($0) } },
        paint: { root, length, cursor, runs in
            SyntaxHighlight.paintXML(run: root, length: length, cursor: &cursor, runs: &runs)
        },
        commentStyle: .block(open: "<!--", close: "-->"),
        brackets: SyntaxProfile.defaultBrackets + [SyntaxProfile.BracketPair(open: "<", close: ">")])

    /// HTML: tag names keyword-colored, attribute names keys, values
    /// strings, comments and the doctype dim, entities numbers. Block
    /// `<!-- -->` comments; auto-pairs `< >` on top of the default set
    /// (tags only ever open with `<`).
    public static let html = SyntaxProfile(
        id: "html",
        language: { tree_sitter_html().map { Language($0) } },
        paint: { root, length, cursor, runs in
            SyntaxHighlight.paintHTML(run: root, length: length, cursor: &cursor, runs: &runs)
        },
        commentStyle: .block(open: "<!--", close: "-->"),
        brackets: SyntaxProfile.defaultBrackets + [SyntaxProfile.BracketPair(open: "<", close: ">")])

    /// JavaScript: strings/numbers/comments in the shared token colors,
    /// keyword tokens, and the callee side of every call
    /// (`client.test(...)`) emphasized as one function-name chain.
    /// Auto-pair table is the default set: `{` stays out so
    /// `{{variable}}` templates in scripts keep working. A trailing `:`
    /// indents the next line; line comments continue.
    public static let javascript = SyntaxProfile(
        id: "javascript",
        language: { tree_sitter_javascript().map { Language($0) } },
        paint: { root, length, cursor, runs in
            SyntaxHighlight.paintJS(run: root, length: length, cursor: &cursor, runs: &runs)
        },
        commentStyle: .line(prefix: "// "),
        onEnterRules: [SyntaxProfile.OnEnterRule(pattern: ".*:\\s*$", action: .indent)],
        continueLineComments: true)

    /// Shell: pipes and redirects stay plain, flags/keywords take the
    /// keyword color, strings and numbers the shared token colors,
    /// variables the key color. `#` line comments.
    /// Auto-pairs `{ }` on top of the default set (brace expansions and
    /// groups); no `{{` template token exists here to protect.
    public static let bash = SyntaxProfile(
        id: "bash",
        language: { tree_sitter_bash().map { Language($0) } },
        paint: { root, length, cursor, runs in
            LanguagePaints.bash(node: root, length: length, cursor: &cursor, runs: &runs)
        },
        commentStyle: .line(prefix: "# "),
        brackets: SyntaxProfile.defaultBrackets + [SyntaxProfile.BracketPair(open: "{", close: "}")],
        onEnterRules: [
            SyntaxProfile.OnEnterRule(pattern: ".*\\bthen\\s*$", action: .indent),
            SyntaxProfile.OnEnterRule(pattern: ".*\\bdo\\s*$", action: .indent),
        ],
        continueLineComments: true)

    /// Lua: keywords and literals, strings/numbers/comments in the
    /// shared token colors, identifiers and member chains as one
    /// key-colored surface. `--` line comments.
    /// Auto-pairs `{ }` on top of the default set (table constructors);
    /// no `{{` template token exists here to protect.
    public static let lua = SyntaxProfile(
        id: "lua",
        language: { tree_sitter_lua().map { Language($0) } },
        paint: { root, length, cursor, runs in
            LanguagePaints.lua(node: root, length: length, cursor: &cursor, runs: &runs)
        },
        commentStyle: .line(prefix: "-- "),
        brackets: SyntaxProfile.defaultBrackets + [SyntaxProfile.BracketPair(open: "{", close: "}")],
        onEnterRules: [
            SyntaxProfile.OnEnterRule(pattern: ".*\\bthen\\s*$", action: .indent),
            SyntaxProfile.OnEnterRule(pattern: ".*\\bdo\\s*$", action: .indent),
            SyntaxProfile.OnEnterRule(pattern: ".*\\belse\\s*$", action: .indent),
            SyntaxProfile.OnEnterRule(pattern: ".*\\brepeat\\s*$", action: .indent),
        ],
        continueLineComments: true)
}
