import AppKit
import SwiftUI
import XCTest

@testable import Plume

/// Renders the editor into a bitmap and checks that committed CJK text
/// actually produces visible pixels - the display half of the IME
/// contract, which storage-level tests cannot cover.
@MainActor
final class IMERenderTest: XCTestCase {
    func testCommittedChineseRendersVisiblePixels() throws {
        let textView = EditorTextView()
        let coordinator = EditorCoordinator(
            EditorRepresentable(
                text: Binding(get: { "say " }, set: { _ in }),
                annotations: nil, restyleKey: "", syntax: .plain,
                isEditable: true, fillsContainer: false, showsLineNumbers: true,
                showsGutterSeparator: false, enablesTypingAssist: true, font: .monoBody,
                formatHandler: nil, formatActionName: "Format", onFormatError: nil,
                suggestFactory: nil, suggestItems: [], onStatsChange: nil, hoverProvider: nil,
                enablesAutoPairing: true, renderWhitespace: .none,
                onContentHeightChange: nil, onGutterWidthChange: nil,
                find: EditorFindState(), findAction: nil, onFindActionHandled: nil,
                findHooks: nil, gotoLine: nil, onGoToLineHandled: nil, onLineCountHint: nil))
        let scrollView = NSScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        let root = EditorRootView(textView: textView, scrollView: scrollView, showsGutter: true)
        root.frame = scrollView.bounds
        scrollView.documentView = textView
        textView.editorCoordinator = coordinator
        coordinator.rootView = root
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        coordinator.replaceAll("say ", in: textView)
        scrollView.layoutSubtreeIfNeeded()
        textView.layoutSubtreeIfNeeded()

        // IME commit (as the input context delivers it).
        textView.setMarkedText("nihao", selectedRange: NSRange(location: 9, length: 0), replacementRange: NSRange(location: 4, length: 0))
        textView.insertText("你好", replacementRange: textView.markedRange())
        textView.layoutSubtreeIfNeeded()

        // Render into a bitmap.
        let size = textView.frame.size
        let image = NSImage(size: size)
        image.lockFocus()
        textView.draw(textView.bounds)
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))

        // Scan the WHOLE bitmap for dark (text) pixels.
        func darkCount(_ rep: NSBitmapImageRep) -> Int {
            var count = 0
            for y in 0..<Int(rep.pixelsHigh) {
                for x in 0..<Int(rep.pixelsWide) {
                    guard let color = rep.colorAt(x: x, y: y) else { continue }
                    var r: CGFloat = 0
                    var g: CGFloat = 0
                    var b: CGFloat = 0
                    var a: CGFloat = 0
                    color.usingColorSpace(.deviceRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
                    if a > 0.9, (r + g + b) / 3 < 0.5 { count += 1 }
                }
            }
            return count
        }
        let withText = darkCount(bitmap)
        XCTAssertGreaterThan(
            withText, 50,
            "committed CJK produced no visible text pixels (total dark: \(withText))")
    }
}
