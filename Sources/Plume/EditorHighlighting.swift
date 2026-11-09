import AppKit
import SwiftTreeSitter

/// Incremental syntax highlighting for `Editor`: one parser + parse
/// tree kept alive per editor, edited through tree-sitter's incremental
/// machinery instead of the full re-parse every keystroke that
/// `SyntaxHighlight.foregroundRuns` does for one-shot painting.
///
/// On each storage edit the engine
/// 1. feeds an `InputEdit` into the retained tree (UTF-16 code-unit offsets
///    double into UTF-16LE byte offsets - SwiftTreeSitter's convention),
/// 2. re-parses against the old tree exactly once and asks for
///    `changedRanges`,
/// 3. returns a repaint window: the edited lines united with everything the
///    parse says moved (a `/*` typed above recolors lines far below), and
/// 4. the fresh runs intersecting that window, from the profile's paint
///    walk.
///
/// The host's annotation washes are line-scoped, so the caller re-tints
/// the same window; the window is always expanded to line boundaries
/// first, which also guarantees an annotation never straddles its edge.
///
/// Anything unexpected (grammar load failure, parse cancellation, text over
/// the shared length cap) degrades to tint-only, matching
/// `SyntaxHighlight`'s contract: highlighting must never break the editor.
final class SourceHighlighter {
    private var profile: SyntaxProfile
    private var parser: Parser?
    private var tree: MutableTree?
    /// UTF-16 offsets of every line start, kept incrementally so the
    /// InputEdit points stay O(edited lines) even on megabyte bodies.
    private var lineStarts: [Int] = [0]

    /// Same cap as `SyntaxHighlight`: beyond it the editor paints
    /// annotations only and skips the grammar entirely.
    private let maxSyntaxLength = 200_000

    init(profile: SyntaxProfile) {
        self.profile = .plain
        setProfile(profile)
    }

    /// Switches the grammar. Rebuilds the parser; the next paint is a full
    /// one. Profiles compare by id (see `SyntaxProfile.==`).
    func setProfile(_ profile: SyntaxProfile) {
        guard profile != self.profile || parser == nil else { return }
        self.profile = profile
        parser = profile.language().flatMap { language in
            let parser = Parser()
            guard (try? parser.setLanguage(language)) != nil else { return nil }
            return parser
        }
        tree = nil
    }

    /// Feeds one storage edit through the incremental pipeline. `text` is
    /// the post-edit document; `editedRange` is NSTextStorage's editedRange
    /// (post-edit coordinates - it spans the characters now occupying the
    /// changed region) and `delta` its changeInLength. Returns the
    /// line-bounded repaint window plus the syntax runs inside it - runs
    /// nil means tint-only (over the cap, parse unavailable).
    func edit(_ text: String, editedRange: NSRange, delta: Int) -> (window: NSRange, runs: [(NSRange, NSColor)]?) {
        let nsText = text as NSString
        let length = nsText.length
        // Clamp against delegate reentry edges (empty documents, programmatic
        // edits racing layout): a malformed range must not crash the editor.
        let start = min(max(editedRange.location, 0), length)
        let newLength = min(max(editedRange.length, 0), length - start)
        let oldLength = max(newLength - delta, 0)
        let oldEnd = start + oldLength
        let newEnd = start + newLength

        let oldLineStarts = lineStarts
        let startLine = Self.lineIndex(of: start, in: oldLineStarts)
        let oldEndLine = Self.lineIndex(of: oldEnd, in: oldLineStarts)
        let startPoint = Point(row: startLine, column: 2 * (start - oldLineStarts[startLine]))
        let oldEndPoint = Point(row: oldEndLine, column: 2 * (oldEnd - oldLineStarts[oldEndLine]))
        lineStarts = Self.updatedLineStarts(
            oldLineStarts,
            span: EditSpan(start: start, oldEnd: oldEnd, newEnd: newEnd, delta: delta),
            text: nsText)
        let newEndLine = Self.lineIndex(of: newEnd, in: lineStarts)
        let newEndPoint = Point(row: newEndLine, column: 2 * (newEnd - lineStarts[newEndLine]))

        // The repaint floor: the lines the edit itself touched.
        var window = Self.lineWindow(
            for: NSRange(location: start, length: newEnd - start),
            lineStarts: lineStarts,
            length: length)

        // The single parse of this edit: incremental against the retained
        // tree, from scratch when there is none (first edit, previous parse
        // failure) or the grammar is unavailable (tint-only degradation).
        var runs: [(NSRange, NSColor)]?
        if length <= maxSyntaxLength, let parser {
            if let oldTree = tree {
                oldTree.edit(
                    InputEdit(
                        startByte: 2 * start,
                        oldEndByte: 2 * oldEnd,
                        newEndByte: 2 * newEnd,
                        startPoint: startPoint,
                        oldEndPoint: oldEndPoint,
                        newEndPoint: newEndPoint))
                if let newTree = parser.parse(tree: oldTree, string: text) {
                    // Everything the parse says moved joins the window: a
                    // `/*` typed above recolors lines far below the caret.
                    for changed in oldTree.changedRanges(from: newTree) {
                        let range = NSRange(
                            location: Int(changed.bytes.lowerBound) / 2,
                            length: (Int(changed.bytes.upperBound) - Int(changed.bytes.lowerBound)) / 2)
                        window = window.union(
                            Self.lineWindow(for: range, lineStarts: lineStarts, length: length))
                    }
                    tree = newTree
                } else {
                    tree = nil
                }
            }
            if let current = tree ?? parser.parse(text) {
                tree = current
                runs = Self.paint(current, profile: profile, length: length)
            } else {
                tree = nil
            }
        }

        return (window, Self.windowRuns(full: runs, window: window))
    }

    // MARK: - Painting

    /// Walks a fresh tree once with the profile's paint. The walk is
    /// O(nodes) - microseconds next to the attribute work - so the caller
    /// filters rather than re-strategizing the traversal.
    private static func paint(_ tree: MutableTree, profile: SyntaxProfile, length: Int) -> [(NSRange, NSColor)]? {
        guard let root = tree.rootNode else { return nil }
        var runs: [(NSRange, NSColor)] = []
        var cursor = 0
        profile.paint(root, length, &cursor, &runs)
        return runs
    }

    /// The runs intersecting the repaint window (nil = tint-only).
    private static func windowRuns(full: [(NSRange, NSColor)]?, window: NSRange) -> [(NSRange, NSColor)]? {
        guard let full else { return nil }
        return full.filter { NSIntersectionRange($0.0, window).length > 0 }
    }

    // MARK: - Line bookkeeping

    /// Total logical lines. A trailing newline opens a phantom line -
    /// editors number it too (it is where the next character lands).
    var lineCount: Int { lineStarts.count }

    /// UTF-16 offsets of every line start (line 1 begins at 0) - the
    /// go-to-line jump reads this ledger.
    var lineStartOffsets: [Int] { lineStarts }

    /// 1-based line and column for a UTF-16 offset (column in characters,
    /// not visual cells) - the editor's diagnostics tooltips read this.
    func lineAndColumn(ofUTF16Offset offset: Int) -> (line: Int, column: Int) {
        let line = lineNumber(ofUTF16Offset: offset)
        let start = lineStarts[line - 1]
        return (line, offset - start + 1)
    }

    /// Syntax diagnostics from the retained tree: the outermost ERROR
    /// nodes ("Syntax error") and MISSING tokens ("Missing x") as UTF-16
    /// ranges. Empty when the tree is clean, plain, or over the cap.
    func diagnostics() -> [(range: NSRange, message: String)] {
        guard let tree, let root = tree.rootNode, root.hasError else { return [] }
        var out: [(range: NSRange, message: String)] = []
        func walk(_ node: Node) {
            if node.nodeType == "ERROR" {
                out.append((node.range, "Syntax error"))
                return  // outermost error wins; its children are the damage
            }
            if node.isMissing {
                out.append((node.range, "Missing \(node.nodeType ?? "token")"))
                return
            }
            guard node.hasError else { return }
            for index in 0..<node.childCount {
                if let child = node.child(at: index) { walk(child) }
            }
        }
        walk(root)
        return out
    }

    /// 1-based logical line number for a UTF-16 offset (clamped). An offset
    /// at or past the last line start lands on the last line - which is the
    /// phantom line when the document ends with a newline, so both share
    /// one clamp.
    func lineNumber(ofUTF16Offset offset: Int) -> Int {
        let clamped = min(max(offset, 0), lineStarts.last ?? 0)
        return Self.lineIndex(of: clamped, in: lineStarts) + 1
    }

    /// SwiftTreeSitter's `parse(_:string:)` feeds the string as UTF-16LE
    /// (see `Parser.readFunction`), so the retained tree's "byte" offsets
    /// are 2 × UTF-16 offsets - the same convention `edit` uses for its
    /// `InputEdit` (`startByte: 2 * start`). These helpers keep the
    /// UTF-16-facing callers in step.
    private static func byteOffset(ofUTF16Offset offset: Int) -> Int { 2 * offset }

    private static func utf16Range(ofByteRange byteRange: Range<UInt32>) -> NSRange {
        NSRange(
            location: Int(byteRange.lowerBound) / 2,
            length: (Int(byteRange.upperBound) - Int(byteRange.lowerBound)) / 2)
    }

    /// Ancestor chain of the smallest syntax node containing `range`:
    /// each distinct node range from innermost to the root, as UTF-16
    /// ranges. Nil without a retained tree (plain profile). The O(n)
    /// ladder walks are fine here: expansion is user-paced.
    func enclosingNodeRanges(of range: NSRange, in text: String) -> [NSRange]? {
        guard let tree, let root = tree.rootNode else { return nil }
        let start = Self.byteOffset(ofUTF16Offset: min(max(range.location, 0), 1 << 28))
        let end = Self.byteOffset(ofUTF16Offset: min(max(NSMaxRange(range), 0), 1 << 28))
        guard var node = root.descendant(in: UInt32(start)..<UInt32(max(end, start)))
        else { return nil }
        var ranges: [NSRange] = []
        var current: Node? = node
        while let walk = current {
            let utf16Range = Self.utf16Range(ofByteRange: walk.byteRange)
            if ranges.last != utf16Range { ranges.append(utf16Range) }
            current = walk.parent
        }
        return ranges
    }

    /// UTF-16 ranges of string/comment nodes in the retained tree (the
    /// bracket colorizer leaves those to the host's own paint). Nil
    /// without a tree.
    func stringAndCommentRanges(in text: String) -> [NSRange]? {
        guard let tree, let root = tree.rootNode else { return nil }
        var out: [NSRange] = []
        func walk(_ node: Node) {
            if let type = node.nodeType,
                type.contains("string") || type.contains("comment")
            {
                out.append(Self.utf16Range(ofByteRange: node.byteRange))
                return
            }
            for index in 0..<node.childCount {
                if let child = node.child(at: index) { walk(child) }
            }
        }
        walk(root)
        return out
    }

    /// Document-outline symbols from the retained tree: function/class/
    /// method/variable declarations plus JSON object keys, in document
    /// order (Monaco's `Ctrl+Shift+O` outline). Empty without a tree.
    /// Best-effort across grammars: name extraction uses the `name`
    /// field, falling back to the first identifier-like named child.
    func documentSymbols(in text: String) -> [EditorDocumentSymbol] {
        guard let tree, let root = tree.rootNode else { return [] }
        let ns = text as NSString
        var out: [EditorDocumentSymbol] = []
        func symbolName(_ node: Node) -> (name: String, range: NSRange)? {
            guard let nameNode = node.child(byFieldName: "name") ?? firstNameLikeChild(of: node) else { return nil }
            let range = Self.utf16Range(ofByteRange: nameNode.byteRange)
            let clamped = NSRange(
                location: min(max(range.location, 0), ns.length),
                length: min(max(range.length, 0), max(0, ns.length - min(max(range.location, 0), ns.length))))
            guard clamped.length > 0 else { return nil }
            var name = ns.substring(with: clamped)
            // JSON object keys arrive quoted; Lua function names arrive dotted.
            if name.hasPrefix("\""), name.hasSuffix("\"") {
                name = String(name.dropFirst().dropLast())
            }
            guard !name.isEmpty else { return nil }
            return (name, clamped)
        }
        func firstNameLikeChild(of node: Node) -> Node? {
            for index in 0..<node.childCount {
                guard let child = node.child(at: index), child.isNamed else { continue }
                let type = child.nodeType ?? ""
                if type.contains("identifier") || type.contains("function_name")
                    || type.contains("method") || type == "word" || type == "variable"
                {
                    return child
                }
            }
            return nil
        }
        func walk(_ node: Node) {
            if let type = node.nodeType {
                switch type {
                case "function_declaration", "function_definition",
                    "generator_function_declaration":
                    if let hit = symbolName(node) {
                        out.append(EditorDocumentSymbol(name: hit.name, range: hit.range, kind: .function))
                    }
                case "class_declaration":
                    if let hit = symbolName(node) {
                        out.append(EditorDocumentSymbol(name: hit.name, range: hit.range, kind: .class))
                    }
                case "method_definition":
                    if let hit = symbolName(node) {
                        out.append(EditorDocumentSymbol(name: hit.name, range: hit.range, kind: .method))
                    }
                case "variable_declarator":
                    if let hit = symbolName(node) {
                        out.append(EditorDocumentSymbol(name: hit.name, range: hit.range, kind: .variable))
                    }
                case "assignment_statement":
                    // Lua `local x =`, `a, b =`: each `variable` lhs is a declaration.
                    for index in 0..<node.childCount {
                        guard let child = node.child(at: index), child.nodeType == "variable" else { continue }
                        let range = Self.utf16Range(ofByteRange: child.byteRange)
                        let clamped = NSRange(
                            location: min(max(range.location, 0), ns.length),
                            length: min(max(range.length, 0), max(0, ns.length - min(max(range.location, 0), ns.length))))
                        guard clamped.length > 0 else { continue }
                        let name = ns.substring(with: clamped)
                        if !name.isEmpty {
                            out.append(EditorDocumentSymbol(name: name, range: clamped, kind: .variable))
                        }
                    }
                case "pair":
                    // JSON object key (string node as first named child).
                    if let key = node.namedChild(at: 0), key.nodeType == "string" {
                        let range = Self.utf16Range(ofByteRange: key.byteRange)
                        let clamped = NSRange(
                            location: min(max(range.location, 0), ns.length),
                            length: min(max(range.length, 0), max(0, ns.length - min(max(range.location, 0), ns.length))))
                        guard clamped.length > 0 else { break }
                        var name = ns.substring(with: clamped)
                        if name.hasPrefix("\""), name.hasSuffix("\"") {
                            name = String(name.dropFirst().dropLast())
                        }
                        if !name.isEmpty {
                            out.append(EditorDocumentSymbol(name: name, range: clamped, kind: .key))
                        }
                    }
                default: break
                }
            }
            for index in 0..<node.childCount {
                if let child = node.child(at: index) { walk(child) }
            }
        }
        walk(root)
        out.sort { $0.range.location < $1.range.location }
        // Dedup identical ranges (nested aliases can repeat a name).
        var seen = Set<String>()
        var deduped: [EditorDocumentSymbol] = []
        for symbol in out {
            let key = "\(symbol.range.location)-\(symbol.range.length)-\(symbol.name)"
            if seen.insert(key).inserted { deduped.append(symbol) }
        }
        return deduped
    }

    /// Whether a UTF-16 offset opens a line (offset 0, or just after `\n`).
    /// The gutter numbers only fragments that start a line, so wrapped
    /// continuations repeat nothing.
    func isLineStart(_ offset: Int) -> Bool {
        guard let last = lineStarts.last, offset <= last else { return false }
        return lineStarts[Self.lineIndex(of: offset, in: lineStarts)] == offset
    }

    private static func lineStartOffsets(in text: String) -> [Int] {
        var starts: [Int] = [0]
        var index = 0
        for unit in text.utf16 {
            // Only `\n` opens a line, matching tree-sitter's own point rows;
            // a lone `\n` unit can never be half a surrogate pair.
            if unit == 0x0A {
                starts.append(index + 1)
            }
            index += 1
        }
        return starts
    }

    /// Last line-start index whose offset is <= `location` (binary search).
    private static func lineIndex(of location: Int, in lineStarts: [Int]) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    /// Line-bounded expansion of `range`: from the start of the line holding
    /// its first character through the start of the line after its last.
    /// Line boundaries guarantee `{{placeholder}}` scans never straddle the
    /// window edge and keep repaint coalescing predictable.
    private static func lineWindow(for range: NSRange, lineStarts: [Int], length: Int) -> NSRange {
        let start = min(max(range.location, 0), length)
        let end = min(max(range.location + range.length, start), length)
        let firstLine = lineIndex(of: start, in: lineStarts)
        let windowStart = lineStarts[firstLine]
        let lastLine = lineIndex(of: max(end - 1, start), in: lineStarts)
        let windowEnd = lastLine + 1 < lineStarts.count ? lineStarts[lastLine + 1] - 1 : length
        return NSRange(location: windowStart, length: max(windowEnd - windowStart, 0))
    }

    /// One character edit in UTF-16 coordinates: post-edit replacement
    /// span (`start`..<`newEnd`), the pre-edit end of the replaced region,
    /// and the length change.
    private struct EditSpan {
        let start: Int
        let oldEnd: Int
        let newEnd: Int
        let delta: Int
    }

    /// Folds one edit into the line-start array: keep entries at or before
    /// the edit, drop starts inside the replaced span (their newlines were
    /// replaced), insert starts for newlines the replacement carries, shift
    /// the tail by the delta. An entry exactly at the old end belongs to a
    /// newline inside the replaced span, so it is dropped too - the scan
    /// re-adds one at the new end when the replacement itself ends in `\n`.
    private static func updatedLineStarts(
        _ old: [Int],
        span: EditSpan,
        text: NSString
    ) -> [Int] {
        var updated: [Int] = []
        updated.reserveCapacity(old.count + 8)
        for offset in old where offset <= span.start {
            updated.append(offset)
        }
        var scan = span.start
        while scan < span.newEnd {
            let found = text.rangeOfCharacter(
                from: CharacterSet(charactersIn: "\n"),
                options: [],
                range: NSRange(location: scan, length: span.newEnd - scan))
            guard found.location != NSNotFound else { break }
            updated.append(found.location + 1)
            scan = found.location + 1
        }
        for offset in old where offset > span.oldEnd {
            updated.append(offset + span.delta)
        }
        return updated
    }
}

extension NSRange {
    /// Unites two ranges into their smallest cover (assumes valid inputs).
    fileprivate func union(_ other: NSRange) -> NSRange {
        let start = min(location, other.location)
        let end = max(NSMaxRange(self), NSMaxRange(other))
        return NSRange(location: start, length: max(end - start, 0))
    }
}
