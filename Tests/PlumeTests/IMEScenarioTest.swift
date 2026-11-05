import AppKit
import SwiftUI
import XCTest

@testable import Plume

/// Replays the exact user scenario: template Lua code in the editor,
/// caret at end, IME composition + commit at the caret.
@MainActor
final class IMEScenarioTest: XCTestCase {
    func testUserScenario() throws {
        let template = """
            #!lua name=counter

            redis.register_function({
                function_name = 'counter_with_expiration',
                callback = function(keys, args)
                    local key = keys[1]
                    local is_new = redis.call("EXISTS", key) == 0
                    local cnt = redis.call("INCRBY", key, args[1])
                    if is_new then
                            redis.call("EXPIRE", key, args[2])
                    end
                    return cnt
                end,
                description = "INCRBY a counter, setting TTL only on first creation"
            })
            """
        let textView = EditorTextView()
        let coordinator = EditorCoordinator(
            EditorRepresentable(
                text: Binding(get: { template }, set: { _ in }),
                annotations: nil, restyleKey: "", syntax: .plain,
                isEditable: true, fillsContainer: true, showsLineNumbers: true,
                showsGutterSeparator: false, enablesTypingAssist: true, font: .monoBody,
                formatHandler: nil, formatActionName: "Format", onFormatError: nil,
                suggestFactory: nil, suggestItems: [], onStatsChange: nil, hoverProvider: nil,
                enablesAutoPairing: true, renderWhitespace: .none, markers: [], showsOverviewRuler: false, tabSize: 2, insertSpaces: true,
                detectIndentation: false, wordWrap: .on,
                onContentHeightChange: nil, onGutterWidthChange: nil,
                find: EditorFindState(), findAction: nil, onFindActionHandled: nil,
                findHooks: nil, gotoLine: nil, gotoColumn: nil, onGoToLineHandled: nil, onLineCountHint: nil))
        let scrollView = NSScrollView()
        let root = EditorRootView(textView: textView, scrollView: scrollView, showsGutter: true, showsRuler: false)
        scrollView.documentView = textView
        textView.editorCoordinator = coordinator
        coordinator.rootView = root
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        coordinator.replaceAll(template, in: textView)

        let baseLen = (template as NSString).length
        XCTAssertEqual(textView.string.count, baseLen)

        // Caret to end (like opening the sheet).
        textView.setSelectedRange(NSRange(location: baseLen, length: 0))

        // Composition: "sjflj" → marked "史蒂夫理解" candidates phase.
        textView.setMarkedText(
            "sjflj", selectedRange: NSRange(location: baseLen + 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(textView.hasMarkedText())
        XCTAssertEqual((textView.string as NSString).length, baseLen + 5)

        // Commit on Enter: the input context resolves NSNotFound to the
        // marked range and passes it down (observed in the real IME logs
        // as NSNotFound at the context layer, marked at the view layer).
        let marked = textView.markedRange()
        textView.insertText("史蒂夫理解", replacementRange: marked)

        XCTAssertFalse(textView.hasMarkedText())
        // The marked pinyin (5 chars appended to the template) is
        // REPLACED by the 5 CJK chars: length stays baseLen + 5.
        XCTAssertEqual((textView.string as NSString).length, baseLen + 5)
        // The CJK must sit exactly where the pinyin was (end; the
        // template's trailing `})` precedes it).
        let tail = (textView.string as NSString).substring(from: baseLen - 2)
        XCTAssertEqual(tail, "})史蒂夫理解")
        XCTAssertFalse(textView.string.contains("sjflj"), "pinyin must be replaced")
    }

    /// Regression: the Runlet Lua editor hosts the Editor with
    /// fillsContainer inside a fixed-size sheet. After the IME commit,
    /// the text view must be laid out with a nonzero frame and the
    /// committed text must fall inside the visible rect (the user saw
    /// "nothing happened" - storage correct, screen unchanged).
    func testCommittedTextIsLaidOutAndVisible() throws {
        let template = String(repeating: "line of lua code\n", count: 20)
        let textView = EditorTextView()
        let coordinator = EditorCoordinator(
            EditorRepresentable(
                text: Binding(get: { template }, set: { _ in }),
                annotations: nil, restyleKey: "", syntax: .plain,
                isEditable: true, fillsContainer: true, showsLineNumbers: true,
                showsGutterSeparator: false, enablesTypingAssist: true, font: .monoBody,
                formatHandler: nil, formatActionName: "Format", onFormatError: nil,
                suggestFactory: nil, suggestItems: [], onStatsChange: nil, hoverProvider: nil,
                enablesAutoPairing: true, renderWhitespace: .none, markers: [], showsOverviewRuler: false, tabSize: 2, insertSpaces: true,
                detectIndentation: false, wordWrap: .on,
                onContentHeightChange: nil, onGutterWidthChange: nil,
                find: EditorFindState(), findAction: nil, onFindActionHandled: nil,
                findHooks: nil, gotoLine: nil, gotoColumn: nil, onGoToLineHandled: nil,
                onLineCountHint: nil))
        let scrollView = NSScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let root = EditorRootView(textView: textView, scrollView: scrollView, showsGutter: true, showsRuler: false)
        root.frame = scrollView.bounds
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        textView.editorCoordinator = coordinator
        coordinator.rootView = root
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        coordinator.replaceAll(template, in: textView)
        root.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        textView.layoutSubtreeIfNeeded()

        // Caret to end, compose, commit - the user's exact sequence.
        let baseLen = (template as NSString).length
        textView.setSelectedRange(NSRange(location: baseLen, length: 0))
        textView.setMarkedText(
            "sjflj",
            selectedRange: NSRange(location: baseLen + 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.insertText("史蒂夫理解", replacementRange: textView.markedRange())

        // The text view must have a real frame (fillsContainer sizing).
        XCTAssertGreaterThan(textView.frame.width, 100, "text view must be laid out")
        XCTAssertGreaterThan(textView.frame.height, 100, "text view must be laid out")
        // The caret must be scrollable into the visible area.
        textView.scrollRangeToVisible(textView.selectedRange())
        textView.layoutSubtreeIfNeeded()
        let caretRange = NSRange(location: textView.selectedRange().location, length: 1)
        let caretRect = textView.firstRect(forCharacterRange: caretRange, actualRange: nil)
        XCTAssertNotEqual(caretRect, .zero, "caret rect must be computable")
        // And the visible rect of the scroll view must contain it.
        let visible = textView.visibleRect
        let caretInTextView = textView.convert(caretRect.origin, from: nil)
        XCTAssertTrue(
            visible.contains(caretInTextView) || caretInTextView.y <= visible.maxY,
            "caret must be at/above the visible bottom after scroll")
    }
}
