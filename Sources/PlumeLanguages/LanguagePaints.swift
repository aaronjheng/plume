import AppKit
import Plume
import SwiftTreeSitter

/// Paint walks for the bundled bash/lua profiles, structured after the
/// core package's JSON/XML/JS walks: depth-first recursion, node types
/// in, role colors out, unknown nodes fall through to their children so
/// grammar drift costs a color, never a crash. Colors read from the
/// host's `EditorTheme` tokens at paint time, exactly like the core
/// walks. Internal: the presets are the only consumers; hosts with
/// different semantics write their own walks.
enum LanguagePaints {
    // MARK: - Bash

    /// Anonymous bash tokens that read as keywords: shell statements,
    /// declarations, and builtins. Anything not on the list falls
    /// through to the generic recursion.
    private static let bashKeywordTokens: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "in", "do", "done",
        "while", "until", "case", "esac", "function", "select", "coproc",
        "return", "local", "export", "readonly", "declare", "unset",
        "source", "exit", "time",
    ]

    static func bash(
        node: Node, length: Int, cursor: inout Int, runs: inout [(NSRange, NSColor)]
    ) {
        guard let type = node.nodeType, !node.isMissing else { return }
        switch type {
        case "comment":
            leaf(node, NSColor(EditorTheme.syntaxPlain), length, &cursor, &runs)
        case "string", "raw_string", "heredoc_body", "ansic_string":
            leaf(node, NSColor(EditorTheme.syntaxString), length, &cursor, &runs)
        case "number":
            leaf(node, NSColor(EditorTheme.syntaxNumber), length, &cursor, &runs)
        case "variable_name", "test_operator":
            leaf(node, NSColor(EditorTheme.syntaxKey), length, &cursor, &runs)
        default:
            if node.childCount == 0, bashKeywordTokens.contains(type) {
                leaf(node, NSColor(EditorTheme.syntaxKeyword), length, &cursor, &runs)
            } else {
                forEachChild(node) { bash(node: $0, length: length, cursor: &cursor, runs: &runs) }
            }
        }
    }

    // MARK: - Lua

    /// Anonymous lua tokens that read as keywords: the language's
    /// statement and literal words.
    private static let luaKeywordTokens: Set<String> = [
        "and", "break", "do", "else", "elseif", "end", "false", "for",
        "function", "goto", "if", "in", "local", "nil", "not", "or",
        "repeat", "return", "then", "true", "until", "while",
    ]

    static func lua(
        node: Node, length: Int, cursor: inout Int, runs: inout [(NSRange, NSColor)]
    ) {
        guard let type = node.nodeType, !node.isMissing else { return }
        switch type {
        case "comment":
            leaf(node, NSColor(EditorTheme.syntaxPlain), length, &cursor, &runs)
        case "string", "string_content":
            leaf(node, NSColor(EditorTheme.syntaxString), length, &cursor, &runs)
        case "number":
            leaf(node, NSColor(EditorTheme.syntaxNumber), length, &cursor, &runs)
        case "identifier", "function_name", "method":
            // API member chains (`redis.call`) read as one key-colored
            // surface, matching the core JS callee treatment.
            leaf(node, NSColor(EditorTheme.syntaxKey), length, &cursor, &runs)
        default:
            if node.childCount == 0, luaKeywordTokens.contains(type) {
                leaf(node, NSColor(EditorTheme.syntaxKeyword), length, &cursor, &runs)
            } else {
                forEachChild(node) { lua(node: $0, length: length, cursor: &cursor, runs: &runs) }
            }
        }
    }

    // MARK: - Shared leaves

    /// Emits one colored run for the node's UTF-16 range (`Node.range` is
    /// already in UTF-16 units on SwiftTreeSitter), clamped against the
    /// document length.
    private static func leaf(
        _ node: Node, _ color: NSColor, _ length: Int,
        _ cursor: inout Int, _ runs: inout [(NSRange, NSColor)]
    ) {
        let range = node.range
        var location = min(max(range.location, 0), length)
        var end = min(max(NSMaxRange(range), location), length)
        if end < location { end = location }
        location = min(location, end)
        guard end - location > 0 else { return }
        if location > cursor { cursor = location }
        runs.append((NSRange(location: location, length: end - location), color))
        cursor = end
    }

    private static func forEachChild(_ node: Node, _ paint: (Node) -> Void) {
        for index in 0..<node.childCount {
            if let child = node.child(at: index) { paint(child) }
        }
    }
}
