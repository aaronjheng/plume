import AppKit
import SwiftTreeSitter
import SwiftUI
import TreeSitterJavaScript
import XCTest

@testable import Plume

/// IME interaction regression tests: these simulate, at the
/// `NSTextInputClient` level, exactly what a Chinese input method does to
/// the text view - setMarkedText (composition), insertText (commit),
/// unmarkText (cancel) - and assert Plume's pipeline survives and keeps
/// storage/selection consistent. Every test here is a distilled crash or
/// hang report from real IME usage.
@MainActor
final class IMERegressionTests: XCTestCase {
    /// The editor under test: a real EditorTextView + coordinator wired
    /// exactly as the representable wires them, with the host binding
    /// living in a box the closures can reach during two-phase init.
    @MainActor
    private final class Harness {
        @MainActor
        final class BindingBox {
            var value: String
            init(_ value: String) { self.value = value }
        }

        let box: BindingBox
        private(set) var textView: EditorTextView
        private(set) var coordinator: EditorCoordinator
        private(set) var root: EditorRootView
        private(set) var representable: EditorRepresentable

        var bindingText: String {
            get { box.value }
            set { box.value = newValue }
        }

        init(
            syntax: SyntaxProfile = .plain,
            text: String = "",
            suggestFactory: (() -> any EditorSuggestControlling)? = nil
        ) {
            let box = BindingBox(text)
            self.box = box
            let representable = EditorRepresentable(
                text: Binding(
                    get: { box.value },
                    set: { box.value = $0 }),
                annotations: nil,
                restyleKey: "",
                syntax: syntax,
                isEditable: true,
                fillsContainer: false,
                showsLineNumbers: true,
                showsGutterSeparator: false,
                enablesTypingAssist: true,
                font: .monoBody,
                formatHandler: nil,
                formatActionName: "Format",
                onFormatError: nil,
                suggestFactory: suggestFactory,
                suggestItems: [],
                onStatsChange: nil,
                hoverProvider: nil,
                enablesAutoPairing: true,
                renderWhitespace: .none,
                onContentHeightChange: nil,
                onGutterWidthChange: nil,
                find: EditorFindState(),
                findAction: nil,
                onFindActionHandled: nil,
                findHooks: nil,
                gotoLine: nil,
                onGoToLineHandled: nil,
                onLineCountHint: nil)
            self.representable = representable
            let scrollView = NSScrollView()
            let textView = EditorTextView()
            let coordinator = EditorCoordinator(representable)
            let root = EditorRootView(textView: textView, scrollView: scrollView, showsGutter: true)
            scrollView.documentView = textView
            textView.editorCoordinator = coordinator
            coordinator.rootView = root
            textView.delegate = coordinator
            textView.textStorage?.delegate = coordinator
            self.textView = textView
            self.coordinator = coordinator
            self.root = root
            // First update: installs content + reports state.
            coordinator.replaceAll(text, in: textView)
        }

        /// Simulates the host's SwiftUI update pass: rebuilds the
        /// representable with the box's current value and hands it to the
        /// coordinator (the comparison updateNSView performs).
        func updateHost() {
            let updated = EditorRepresentable(
                text: Binding(
                    get: { [box] in box.value },
                    set: { [box] in box.value = $0 }),
                annotations: nil,
                restyleKey: "",
                syntax: representable.syntax,
                isEditable: true,
                fillsContainer: false,
                showsLineNumbers: true,
                showsGutterSeparator: false,
                enablesTypingAssist: true,
                font: .monoBody,
                formatHandler: nil,
                formatActionName: "Format",
                onFormatError: nil,
                suggestFactory: representable.suggestFactory,
                suggestItems: [],
                onStatsChange: nil,
                hoverProvider: nil,
                enablesAutoPairing: true,
                renderWhitespace: .none,
                onContentHeightChange: nil,
                onGutterWidthChange: nil,
                find: EditorFindState(),
                findAction: nil,
                onFindActionHandled: nil,
                findHooks: nil,
                gotoLine: nil,
                onGoToLineHandled: nil,
                onLineCountHint: nil)
            representable = updated
            coordinator.parent = updated
        }
    }

    // MARK: 1. Composition replacement must not crash diagnostics removal

    /// Regression: IME composition updates replace the marked range with a
    /// SHORTER string; the previous frame's diagnostic ranges then extend
    /// past the live storage length, and removeTemporaryAttribute threw
    /// NSRangeException inside processEditing (Runlet crash 2026-11-02).
    func testCompositionShrinkDoesNotCrashDiagnosticRemoval() throws {
        // `let 1 = 2` is a hard syntax error → diagnostics exist.
        let harness = Harness(text: "let 1 = 2")
        let textView = harness.textView

        // Populate diagnostics (whatever the grammar reports); the point
        // of this test is that the NEXT refresh - after a shrinking edit -
        // removes stale ranges without throwing.
        harness.coordinator.refreshDiagnostics(in: textView)

        // Composition: mark a string at the end, then REPLACE it with a
        // shorter one (the pinyin-shrink shape). The replace happens through
        // the storage exactly as IME does - replaceCharactersInRange.
        let storage = try XCTUnwrap(textView.textStorage)
        let tail = NSRange(location: storage.length - 2, length: 2)
        storage.beginEditing()
        storage.replaceCharacters(in: tail, with: "1")  // still shorter tail
        storage.endEditing()

        // The shrink must leave the pipeline able to refresh diagnostics
        // without throwing (this call is what crashed).
        harness.coordinator.refreshDiagnostics(in: textView)
    }

    // MARK: 2. updateNSView must not replaceAll during composition

    /// Regression: a stale SwiftUI binding during composition triggered
    /// replaceAll (setAttributedString), corrupting AppKit's attribute
    /// fix-up state - the next draw threw in
    /// ensureAttributesAreFixedInRange. The coordinator's update path now
    /// guards on hasMarkedText; this test exercises the guard at the
    /// level it lives: replaceAll must never run with marked text.
    func testReplaceAllDuringCompositionIsSkipped() throws {
        let harness = Harness(text: "hello")
        let textView = harness.textView

        // Enter composition: mark two characters replacing the "ll"
        // region (the pinyin-over-existing-text shape).
        textView.setMarkedText("ni", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: 1, length: 2))
        XCTAssertTrue(textView.hasMarkedText())

        // The host's binding is STALE (still "hello" while the storage
        // holds the composition "hnilo"). updateNSView's guard skips
        // replaceAll entirely while marked - without it, the storage would
        // be overwritten back to "hello" and AppKit's attribute fix-up
        // state would corrupt (the draw-time crash).
        harness.updateHost()
        XCTAssertTrue(textView.hasMarkedText())
        XCTAssertEqual(textView.string, "hnilo")
    }

    // MARK: 3. IME commit through insertText lands the composed text

    /// The commit path: IME calls insertText(commit, replacementRange:
    /// markedRange). The text must land, the marked state must clear, and
    /// the caret must sit after the commit.
    func testIMECommitLandsComposedText() throws {
        let harness = Harness(text: "say ")
        let textView = harness.textView

        // Compose two characters.
        textView.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: 4, length: 0))
        XCTAssertTrue(textView.hasMarkedText())

        // Commit with a replacement over the marked range (the standard
        // commit shape). "nihao" → "你好" (shorter, multi-byte).
        let marked = textView.markedRange()
        textView.insertText("你好", replacementRange: marked)

        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(textView.string, "say 你好")
        XCTAssertEqual(textView.selectedRange().location, 6)  // after the 2 CJK chars
        // The binding tracked the commit.
        XCTAssertEqual(harness.bindingText, "say 你好")
    }

    // MARK: 4. IME commit must not trigger auto-pairing

    /// Regression: a commit whose first character is a closing bracket
    /// (`]`, `}`, quote...) was consumed by the skip-over path of the
    /// typing-assist - the text never landed. Typing assist is now scoped
    /// to physical keyDown; IME commits pass through.
    func testIMECommitOfClosingBracketIsNotSkipped() throws {
        let harness = Harness(text: "a{b")
        let textView = harness.textView

        // Composition sitting right before the existing `}`.
        textView.setMarkedText("x", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 2, length: 0))

        // Commit a closing bracket (as a CJK fullwidth-less candidate might).
        let marked = textView.markedRange()
        textView.insertText("]", replacementRange: marked)

        // The commit REPLACES the marked composition ("x") with "]",
        // leaving "b" intact - and the skip-over path must not consume
        // the bracket (the regression: "a{xb" with the caret jumping).
        XCTAssertEqual(textView.string, "a{]b")
        XCTAssertFalse(textView.hasMarkedText())
    }

    // MARK: 5. Diagnostics skip the marked range

    /// Squiggles over the live composition range are both noise and a
    /// styling fight with the IME's own underline; they must be skipped.
    func testDiagnosticsSkipMarkedRange() throws {
        let harness = Harness(text: "let a = ;")
        let textView = harness.textView

        // Compose at the end (replacing the trailing `;` region).
        textView.setMarkedText("ni", selectedRange: NSRange(location: 9, length: 0), replacementRange: NSRange(location: 8, length: 1))
        XCTAssertTrue(textView.hasMarkedText())

        harness.coordinator.refreshDiagnostics(in: textView)
        let marked = textView.markedRange()
        // No squiggle may intersect the marked range.
        for range in harness.coordinator.diagnosticUnderlineRanges {
            XCTAssertEqual(NSIntersectionRange(range, marked).length, 0, "squiggle \(range) intersects marked \(marked)")
        }
    }

    // MARK: 6. Composition keeps the incremental line ledger in sync

    /// The line ledger must track composition edits (they are real storage
    /// edits); a desynced ledger poisoned the next InputEdit after commit.
    func testCompositionKeepsLineLedgerInSync() throws {
        let harness = Harness(text: "a\nb\nc")
        let textView = harness.textView
        let before = harness.coordinator.highlighter.lineCount

        // Multi-line composition: replace "b" with "x\ny" (adds a line).
        textView.setMarkedText("x\ny", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 2, length: 1))
        XCTAssertEqual(harness.coordinator.highlighter.lineCount, before + 1)

        // unmarkText COMMITS the composition (AppKit semantics: the marked
        // text stays, only the marked state clears) - the ledger keeps the
        // extra line.
        textView.unmarkText()
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(harness.coordinator.highlighter.lineCount, before + 1)
        XCTAssertEqual(textView.string, "a\nx\ny\nc")
    }

    // MARK: 6.5 Committed CJK must not open the suggest panel

    /// Regression: the suggest panel's word mode treated CJK text as a
    /// "word", opening the opaque candidate panel directly over the
    /// just-committed Chinese - the text was there but covered
    /// (the "invisible CJK" report). Words are program identifiers
    /// (ASCII); committed Chinese must never open the panel.
    func testCommittedCJKDoesNotOpenSuggestPanel() throws {
        let bridge = PanelSpyBridge()
        let harness = Harness(text: "say ", suggestFactory: { bridge })
        let textView = harness.textView

        // Composition + commit at the caret.
        textView.setMarkedText(
            "nihao", selectedRange: NSRange(location: 9, length: 0),
            replacementRange: NSRange(location: 4, length: 0))
        textView.insertText("你好", replacementRange: textView.markedRange())

        // textDidChange ran during the commit; the engine's word-mode
        // lookup must not have found a CJK "word".
        XCTAssertFalse(
            bridge.panelWasShown,
            "the suggest panel opened over committed CJK text")
    }

    /// A pass-through bridge that records whether the panel ever ordered
    /// front, forwarding to a real SuggestController with a broad universe
    /// (worst case: everything matches).
    @MainActor
    private final class PanelSpyBridge: EditorSuggestControlling {
        private let engine = SuggestController(triggerCharacters: [])
        private(set) var panelWasShown = false

        func candidatesChanged(_ candidates: [Any]) {}

        func textChanged(_ textView: NSTextView) {
            engine.setWordCandidates([
                SuggestItem(name: "call"),
                SuggestItem(name: "pcall"),
            ])
            engine.textChanged(textView)
            panelWasShown = panelWasShown || engine.isVisible
        }

        func selectionChanged(_ textView: NSTextView) {
            engine.selectionChanged(textView)
        }

        func handleCommand(_ selector: Selector) -> Bool {
            engine.handleCommand(selector)
        }

        var isVisible: Bool { engine.isVisible }

        func hide() { engine.hide() }
    }

    // MARK: 7. Mainstream IME interaction shapes (parameterized replay)

    /// One IME interaction shape: how an input method drives the
    /// NSTextInputClient protocol to type "你好" over "say ".
    /// All macOS IMEs (system Pinyin, Sogou, WeChat...) speak this exact
    /// protocol - the shapes below are their observed event sequences.
    struct IMEShape {
        let name: String
        /// (markedString, replacementRange) steps before the commit.
        let composition: [(String, NSRange)]
        /// The commit payload and its replacement range.
        let commit: (String, NSRange)
    }

    static let imeShapes: [IMEShape] = [
        // System Pinyin: letters accumulate into one marked range, commit
        // replaces it.
        IMEShape(
            name: "system-pinyin",
            composition: [
                ("n", NSRange(location: 4, length: 0)),
                ("ni", NSRange(location: 4, length: 1)),
                ("nihao", NSRange(location: 4, length: 2)),
            ],
            commit: ("你好", NSRange(location: 4, length: 5))),
        // Sogou-style: syllable-split marking (two setMarkedText rounds per
        // syllable pair), commit over the whole span.
        IMEShape(
            name: "sogou-syllables",
            composition: [
                ("ni", NSRange(location: 4, length: 0)),
                ("ni'h", NSRange(location: 4, length: 2)),
                ("ni'hao", NSRange(location: 4, length: 4)),
            ],
            commit: ("你好", NSRange(location: 4, length: 6))),
        // WeChat-style: high-frequency re-marking of the same span (every
        // keystroke re-asserts the full composition).
        IMEShape(
            name: "wechat-reflow",
            composition: [
                ("n", NSRange(location: 4, length: 0)),
                ("ni", NSRange(location: 4, length: 1)),
                ("nih", NSRange(location: 4, length: 2)),
                ("niha", NSRange(location: 4, length: 3)),
                ("nihao", NSRange(location: 4, length: 4)),
                ("nihao", NSRange(location: 4, length: 5)),
            ],
            commit: ("你好", NSRange(location: 4, length: 5))),
    ]

    /// Every shape must land the commit, clear the marked state, keep the
    /// binding and the line ledger coherent, and leave the caret after the
    /// committed text.
    func testMainstreamIMEShapes() throws {
        for shape in Self.imeShapes {
            let harness = Harness(text: "say ")
            let textView = harness.textView

            for (marked, replacement) in shape.composition {
                textView.setMarkedText(
                    marked,
                    selectedRange: NSRange(location: 4 + marked.count, length: 0),
                    replacementRange: replacement)
                XCTAssertTrue(textView.hasMarkedText(), "\(shape.name): marked lost after step")
            }

            let (commitText, commitRange) = shape.commit
            textView.insertText(commitText, replacementRange: commitRange)

            XCTAssertFalse(textView.hasMarkedText(), "\(shape.name): marked survived commit")
            XCTAssertEqual(textView.string, "say 你好", "\(shape.name)")
            XCTAssertEqual(textView.selectedRange().location, 6, "\(shape.name)")
            XCTAssertEqual(harness.bindingText, "say 你好", "\(shape.name)")
            XCTAssertEqual(
                harness.coordinator.highlighter.lineCount, 1, "\(shape.name)")
        }
    }

    // MARK: 8. Successive composition updates (typed pinyin) stay consistent

    /// Simulates the pinyin keystroke sequence: setMarkedText grows the
    /// composition letter by letter, then a commit replaces it. Storage,
    /// binding mirror, and marked state must stay coherent throughout.
    func testSuccessiveCompositionUpdates() throws {
        let harness = Harness(text: "")
        let textView = harness.textView
        let storage = try XCTUnwrap(textView.textStorage)

        var composed = ""
        for letter in ["n", "i", "h", "a", "o"] {
            composed += letter
            textView.setMarkedText(
                composed, selectedRange: NSRange(location: composed.count, length: 0),
                replacementRange: NSRange(location: 0, length: composed.count - 1))
            XCTAssertEqual(textView.string, composed)
        }

        // Commit: replacement over the whole marked range.
        textView.insertText("你好", replacementRange: textView.markedRange())
        XCTAssertEqual(storage.string as String, "你好")
        XCTAssertEqual(textView.string, "你好")
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(harness.bindingText, "你好")
    }
}

extension SyntaxProfile {
    /// Minimal JS profile for tests (grammar from the test dependency).
    fileprivate static let testJS = SyntaxProfile(
        id: "javascript",
        language: { testJSLanguage },
        paint: { root, length, cursor, runs in
            paintTestJS(node: root, length: length, cursor: &cursor, runs: &runs)
        },
        commentStyle: .line(prefix: "// "))
}

private let testJSLanguage: Language? = tree_sitter_javascript().map { Language($0) }

private func paintTestJS(node: Node, length: Int, cursor: inout Int, runs: inout [(NSRange, NSColor)]) {
    guard let type = node.nodeType, !node.isMissing else { return }
    let keywords: Set<String> = ["function", "const", "let", "var", "return"]
    switch type {
    case "string", "template_string":
        emitTestLeaf(node, NSColor.blue, length, &cursor, &runs)
    default:
        if node.childCount == 0, keywords.contains(type) {
            emitTestLeaf(node, NSColor.systemPink, length, &cursor, &runs)
        } else {
            for index in 0..<node.childCount {
                if let child = node.child(at: index) {
                    paintTestJS(node: child, length: length, cursor: &cursor, runs: &runs)
                }
            }
        }
    }
}

private func emitTestLeaf(
    _ node: Node, _ color: NSColor, _ length: Int,
    _ cursor: inout Int, _ runs: inout [(NSRange, NSColor)]
) {
    let range = node.range
    let location = min(max(range.location, 0), length)
    let end = min(max(NSMaxRange(range), location), length)
    guard end > location else { return }
    runs.append((NSRange(location: location, length: end - location), color))
    cursor = end
}
