import AppKit
import SwiftUI

/// One signature to show for a call (Monaco's `SignatureHelp`): the
/// signature text, which parameter is active, and an optional note.
public struct EditorSignatureHelp: Equatable, Sendable {
    /// e.g. `redis.call(key, argv...)`.
    public let signature: String
    /// Zero-based index of the parameter under the caret.
    public let activeParameter: Int
    /// Optional one-line note, e.g. a return type.
    public let documentation: String?

    public init(signature: String, activeParameter: Int, documentation: String? = nil) {
        self.signature = signature
        self.activeParameter = max(activeParameter, 0)
        self.documentation = documentation
    }
}

/// The signature popup's content: one signature line with the active
/// parameter emphasized, plus an optional documentation line.
public struct SignatureHelpPanel: View {
    let help: EditorSignatureHelp

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(attributedSignature)
                .font(EditorTheme.fontMonoSubheadline)
                .lineLimit(2)
            if let documentation = help.documentation, !documentation.isEmpty {
                Text(documentation)
                    .font(EditorTheme.fontSmall)
                    .foregroundStyle(EditorTheme.tertiaryText)
                    .lineLimit(2)
            }
        }
        .padding(EditorTheme.spaceSmall)
        .background(
            RoundedRectangle(cornerRadius: EditorTheme.radiusMedium, style: .continuous)
                .fill(EditorTheme.controlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: EditorTheme.radiusMedium, style: .continuous)
                .strokeBorder(EditorTheme.border, lineWidth: EditorTheme.lineField)
        )
        .shadow(color: EditorTheme.popupShadow, radius: 10, y: 3)
    }

    /// Emphasizes the parameter at `activeParameter` inside the top-level
    /// parentheses; falls back to plain text when no parameter list parses.
    private var attributedSignature: AttributedString {
        guard let range = parameterRange(in: help.signature, at: help.activeParameter) else {
            return AttributedString(help.signature)
        }
        let before = String(help.signature[..<range.lowerBound])
        let active = String(help.signature[range])
        let after = String(help.signature[range.upperBound...])
        var result = AttributedString(before)
        var activePart = AttributedString(active)
        activePart.foregroundColor = EditorTheme.accent
        activePart.font = EditorTheme.fontMonoSubheadline.bold()
        result += activePart
        result += AttributedString(after)
        return result
    }

    private func parameterRange(in signature: String, at index: Int) -> Range<String.Index>? {
        guard let open = signature.firstIndex(of: "("),
            let close = signature.lastIndex(of: ")"),
            open < close
        else { return nil }
        let inner = signature[signature.index(after: open)..<close]
        if inner.trimmingCharacters(in: .whitespaces).isEmpty {
            return index == 0 ? nil : nil
        }
        var segments: [Range<String.Index>] = []
        var start = signature.index(after: open)
        var depth = 0
        var cursor = start
        while cursor < close {
            let ch = signature[cursor]
            switch ch {
            case "(", "[", "{":
                depth += 1
            case ")", "]", "}":
                depth -= 1
            case "," where depth == 0:
                segments.append(start..<cursor)
                start = signature.index(after: cursor)
            default: break
            }
            cursor = signature.index(after: cursor)
        }
        segments.append(start..<close)
        guard segments.indices.contains(index) else { return nil }
        // Trim the segment to its non-whitespace core for a tight highlight.
        let segment = segments[index]
        let trimmed = segment
        return trimmed
    }
}

/// Drives the signature popup for one text view: trims the enclosing
/// `name(` around the caret, asks the host's provider, and shows the
/// signature anchored below the caret. Auto-appears on `(`/`,`; once
/// visible it tracks the caret and re-queries on every keystroke.
@MainActor
final class SignatureHelpController: NSObject {
    /// The provider: the function-name range and the computed active
    /// parameter (commas at depth 1 inside the call) map to help text.
    typealias Provider = (NSRange, Int) -> EditorSignatureHelp?

    private var provider: Provider?
    private weak var textView: NSTextView?
    private var current: EditorSignatureHelp?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<SignatureHelpPanel>?
    private var isWatchingDismissal = false
    private var mouseDownMonitor: Any?

    var isVisible: Bool { current != nil }

    func setProvider(_ provider: Provider?) {
        self.provider = provider
        if provider == nil { hide() }
    }

    /// Inserts called from the coordinator's text/selection delegates.
    func textChanged(_ textView: NSTextView) {
        self.textView = textView
        if isVisible {
            refresh(in: textView)
            return
        }
        // Auto-open only on the keystrokes that start or advance a call.
        let caret = textView.selectedRange().location
        guard caret > 0, textView.isEditable,
            textView.selectedRange().length == 0, !textView.hasMarkedText()
        else { return }
        let previous = (textView.string as NSString)
            .substring(with: NSRange(location: caret - 1, length: 1))
        guard previous == "(" || previous == "," else { return }
        show(in: textView)
    }

    func selectionChanged(_ textView: NSTextView) {
        self.textView = textView
        if isVisible { refresh(in: textView) }
    }

    /// Explicit ⌃⇧Space: show even without a fresh `(`/`,`.
    func showExplicitly(in textView: NSTextView) {
        self.textView = textView
        show(in: textView)
    }

    func hide() {
        current = nil
        if let panel {
            panel.orderOut(nil)
            panel.parent?.removeChildWindow(panel)
        }
        if isWatchingDismissal {
            isWatchingDismissal = false
            NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
        }
        if let monitor = mouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDownMonitor = nil
        }
    }

    /// Handles Esc while the popup is up.
    @discardableResult
    func handleCommand(_ selector: Selector) -> Bool {
        guard isVisible else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            hide()
            return true
        }
        return false
    }

    // MARK: - Session

    private func refresh(in textView: NSTextView) {
        guard let help = Self.resolve(in: textView, provider: provider) else {
            hide()
            return
        }
        current = help
        render(for: textView)
    }

    private func show(in textView: NSTextView) {
        guard textView.isEditable, textView.selectedRange().length == 0,
            !textView.hasMarkedText()
        else { return }
        guard let help = Self.resolve(in: textView, provider: provider) else { return }
        current = help
        render(for: textView)
    }

    private static func resolve(in textView: NSTextView, provider: Provider?) -> EditorSignatureHelp? {
        guard let provider else { return nil }
        let ns = textView.string as NSString
        let caret = min(max(textView.selectedRange().location, 0), ns.length)
        guard let call = callContext(in: ns, caret: caret) else { return nil }
        return provider(call.functionRange, call.activeParameter)
    }

    /// The `name(` enclosing the caret, plus the parameter index
    /// (direct commas inside the call, strings and nested pairs skipped).
    private struct CallContext {
        let functionRange: NSRange
        let activeParameter: Int
    }

    private static func callContext(in ns: NSString, caret: Int) -> CallContext? {
        guard caret > 0,
            let openPos = enclosingOpenParen(in: ns, caret: caret)
        else { return nil }
        // Active param: direct commas from the open to the caret.
        var commas = 0
        var depthParen = 1
        var depthBracket = 0
        var depthBrace = 0
        var quote: Character?
        for offset in (openPos + 1)..<caret {
            guard let ch = codeEditorChar(ns, offset) else { continue }
            if let activeQuote = quote {
                if ch == activeQuote { quote = nil }
                continue
            }
            switch ch {
            case "\"", "'", "`":
                quote = ch
            case "(":
                depthParen += 1
            case ")":
                depthParen -= 1
            case "[":
                depthBracket += 1
            case "]":
                depthBracket -= 1
            case "{":
                depthBrace += 1
            case "}":
                depthBrace -= 1
            case "," where depthParen == 1 && depthBracket == 0 && depthBrace == 0:
                commas += 1
            default: break
            }
        }
        // Function name: the identifier chain immediately before `(`.
        var nameEnd = openPos
        while nameEnd > 0, codeEditorChar(ns, nameEnd - 1) == " " || codeEditorChar(ns, nameEnd - 1) == "\t" {
            nameEnd -= 1
        }
        var nameStart = nameEnd
        while nameStart > 0 {
            guard let ch = codeEditorChar(ns, nameStart - 1) else { break }
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "." || ch == ":" {
                nameStart -= 1
            } else {
                break
            }
        }
        guard nameStart < nameEnd else { return nil }
        // A leading `.` or `:` (method `:func`) belongs to the chain;
        // a bare keyword ending proves no real name (`if (`, `for (`):
        // let the provider return nil for those by still passing the
        // keyword range — hosts return nil for builtins they ignore.
        return CallContext(
            functionRange: NSRange(location: nameStart, length: nameEnd - nameStart),
            activeParameter: commas)
    }

    private static func enclosingOpenParen(in ns: NSString, caret: Int) -> Int? {
        var depth = 0
        var quote: Character?
        var index = min(caret, ns.length) - 1
        while index >= 0 {
            guard let ch = codeEditorChar(ns, index) else {
                index -= 1
                continue
            }
            if let activeQuote = quote {
                if ch == activeQuote { quote = nil }
            } else if ch == "\"" || ch == "'" || ch == "`" {
                quote = ch
            } else if ch == ")" {
                depth += 1
            } else if ch == "(" {
                if depth == 0 { return index }
                depth -= 1
            }
            index -= 1
        }
        return nil
    }

    // MARK: - Panel

    private func render(for textView: NSTextView) {
        guard let help = current else { return }
        let panel = ensurePanel()
        hostingView?.rootView = SignatureHelpPanel(help: help)
        guard let frame = anchoredFrame(for: textView) else {
            hide()
            return
        }
        panel.setFrame(frame, display: true)
        if let window = textView.window {
            if panel.parent !== window {
                panel.parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
            }
        }
        panel.orderFront(nil)
        registerDismissWatchers()
    }

    private func anchoredFrame(for textView: NSTextView) -> NSRect? {
        guard let help = current, let window = textView.window,
            var caretRect = caretScreenRect(for: textView)
        else { return nil }
        if caretRect.isEmpty {
            let viewRect = textView.convert(textView.bounds, to: nil)
            caretRect = window.convertToScreen(viewRect)
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(caretRect) }) ?? window.screen else { return nil }
        let visible = screen.visibleFrame
        let width: CGFloat = 340
        let height: CGFloat = help.documentation?.isEmpty == false ? 84 : 56
        let gap: CGFloat = 2
        var origin = NSPoint(x: caretRect.minX - 2, y: caretRect.minY - gap - height)
        if origin.y < visible.minY {
            let aboveY = caretRect.maxY + gap
            origin.y = aboveY + height <= visible.maxY ? aboveY : max(visible.minY, min(origin.y, visible.maxY - height))
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - width)
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }

    private func caretScreenRect(for textView: NSTextView) -> NSRect? {
        guard let layoutManager = textView.layoutManager,
            let container = textView.textContainer,
            let window = textView.window
        else { return nil }
        let ns = textView.string as NSString
        let caretLocation = textView.selectedRange().location
        let characterRange: NSRange
        if caretLocation < ns.length {
            characterRange = NSRange(location: caretLocation, length: 1)
        } else if ns.length > 0 {
            characterRange = NSRange(location: ns.length - 1, length: 1)
        } else {
            characterRange = NSRange(location: 0, length: 0)
        }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        guard lineRect.width > 0, lineRect.height > 0 else { return nil }
        let caretX = caretLocation < ns.length ? lineRect.minX : lineRect.maxX
        let viewRect = NSRect(
            x: caretX + textView.textContainerOrigin.x,
            y: lineRect.minY + textView.textContainerOrigin.y,
            width: 1, height: lineRect.height)
        return window.convertToScreen(textView.convert(viewRect, to: nil))
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true
        panel.worksWhenModal = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: SignatureHelpPanel(help: EditorSignatureHelp(signature: "", activeParameter: 0)))
        panel.contentView = hosting
        hostingView = hosting
        self.panel = panel
        return panel
    }

    private func registerDismissWatchers() {
        guard !isWatchingDismissal else { return }
        isWatchingDismissal = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil)
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleClickOutside(event) }
            return event
        }
    }

    @objc private func appDidResignActive() { hide() }

    private func handleClickOutside(_ event: NSEvent) {
        guard let textView, isVisible else { return }
        if let panel, event.window === panel { return }
        let locationInEditor = textView.convert(event.locationInWindow, from: nil)
        if event.window === textView.window, textView.bounds.contains(locationInEditor) {
            return
        }
        hide()
    }
}
