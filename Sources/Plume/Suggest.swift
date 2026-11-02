import AppKit
import SwiftUI

/// One candidate row in the suggest panel: the name to insert plus
/// optional metadata. Hosts subclass nothing - they hand plain values.
public struct SuggestItem: Identifiable, Hashable, Sendable {
    public let name: String
    /// Optional one-line explanation shown as the row tooltip.
    public var summary: String?

    public init(name: String, summary: String? = nil) {
        self.name = name
        self.summary = summary
    }

    public var id: String { name }
}

/// Parses the fragment under the caret for the suggest panel: either
/// a host-declared trigger prefix (e.g. `{{` - the fragment runs to the
/// caret, closed by an optional trailing close token) or a bare word.
public enum SuggestEngine {
    /// The active fragment at the caret, plus the ranges acceptance replaces.
    public struct Context: Equatable {
        /// UTF-16 range of the fragment in the editor string.
        public let fragmentRange: NSRange
        /// Raw fragment text.
        public let fragment: String
        /// Range of a close token immediately after the caret (e.g. `}}`
        /// when the caret sits inside an already-closed placeholder).
        public let trailingCloseRange: NSRange?

        public init(
            fragmentRange: NSRange, fragment: String, trailingCloseRange: NSRange? = nil
        ) {
            self.fragmentRange = fragmentRange
            self.fragment = fragment
            self.trailingCloseRange = trailingCloseRange
        }

        /// The range acceptance replaces: the fragment plus a trailing
        /// close token when present.
        public var replacementRange: NSRange {
            let trailingLength = trailingCloseRange.map(\.length) ?? 0
            return NSRange(
                location: fragmentRange.location,
                length: fragmentRange.length + trailingLength)
        }
    }

    /// Fragments longer than this are pasted blobs, not names.
    private static let maxFragmentLength = 100

    /// The trigger-prefix context at `caret` (e.g. `{{name`), or nil. The
    /// nearest unclosed `open` wins; a close token before the caret voids
    /// the context.
    public static func triggerContext(
        atCaret caret: Int, in text: String, open: String, close: String
    ) -> Context? {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length else { return nil }
        let openRange = ns.range(of: open, options: [.backwards], range: NSRange(location: 0, length: caret))
        guard openRange.location != NSNotFound else { return nil }
        let fragmentStart = NSMaxRange(openRange)
        guard caret >= fragmentStart else { return nil }
        let fragment = ns.substring(with: NSRange(location: fragmentStart, length: caret - fragmentStart))
        guard !fragment.contains(close.first.map(String.init) ?? "}") else { return nil }
        var trailingCloseRange: NSRange?
        if caret + close.count <= ns.length,
            ns.substring(with: NSRange(location: caret, length: close.count)) == close
        {
            trailingCloseRange = NSRange(location: caret, length: close.count)
        }
        return Context(
            fragmentRange: NSRange(location: fragmentStart, length: caret - fragmentStart),
            fragment: fragment,
            trailingCloseRange: trailingCloseRange)
    }

    /// The bare word ending at the caret, or nil. Words are program
    /// identifiers - ASCII letters, digits, `-`, `_` - NOT CJK text:
    /// committed Chinese must never open the suggest panel (its opaque
    /// background covers the just-committed text - the invisible-CJK bug).
    public static func wordContext(atCaret caret: Int, in text: String) -> Context? {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length, caret > 0 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        var start = caret
        while start > 0 {
            let character = ns.substring(with: NSRange(location: start - 1, length: 1))
            guard !character.isEmpty,
                character.rangeOfCharacter(from: allowed) != nil
            else { break }
            start -= 1
        }
        let length = caret - start
        guard length > 0, length <= maxFragmentLength else { return nil }
        return Context(
            fragmentRange: NSRange(location: start, length: length),
            fragment: ns.substring(with: NSRange(location: start, length: length)),
            trailingCloseRange: nil)
    }

    /// Candidates matching the fragment: case-insensitive prefix matches
    /// first, then substring matches, keeping the given (sorted) order.
    public static func suggestions(
        matching context: Context, from candidates: [SuggestItem]
    ) -> [SuggestItem] {
        let query = context.fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count <= maxFragmentLength else { return [] }
        guard !query.isEmpty else { return candidates }
        let lowered = query.lowercased()
        let prefix = candidates.filter { $0.name.lowercased().hasPrefix(lowered) }
        let contains = candidates.filter {
            !$0.name.lowercased().hasPrefix(lowered) && $0.name.lowercased().contains(lowered)
        }
        return prefix + contains
    }
}

/// The suggestion panel's SwiftUI content: candidate rows plus a keyboard
/// hint footer. Selection is owned by the controller; hover mirrors it.
public struct SuggestPanel: View {
    let suggestions: [SuggestItem]
    @Binding var selectedIndex: Int
    let onHover: (Bool, Int) -> Void
    let onPick: (Int) -> Void
    /// Wrap each row in the trigger's open/close tokens (e.g. `{{name}}`);
    /// plain-name mode (suggest) shows the bare name.
    var openToken: String?
    var closeToken: String?

    static let rowHeight: CGFloat = 24
    static let footerHeight: CGFloat = 20
    static let maxVisibleRows = 8
    static let panelWidth: CGFloat = 280

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            row(index, suggestion)
                        }
                    }
                }
                .onChange(of: selectedIndex) { _, newIndex in
                    guard suggestions.indices.contains(newIndex) else { return }
                    proxy.scrollTo(suggestions[newIndex].id)
                }
            }
            footer
        }
        .frame(width: Self.panelWidth)
        .background(
            RoundedRectangle(cornerRadius: EditorTheme.radiusMedium, style: .continuous)
                .fill(EditorTheme.controlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: EditorTheme.radiusMedium, style: .continuous)
                .strokeBorder(EditorTheme.border, lineWidth: EditorTheme.lineField)
        )
        .clipShape(RoundedRectangle(cornerRadius: EditorTheme.radiusMedium, style: .continuous))
    }

    private func row(_ index: Int, _ suggestion: SuggestItem) -> some View {
        HStack(spacing: EditorTheme.spaceXSmall) {
            Text(displayName(of: suggestion))
                .font(EditorTheme.fontMonoSubheadline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: EditorTheme.spaceSmall)
            if let summary = suggestion.summary {
                Text(summary)
                    .font(EditorTheme.fontSmall)
                    .foregroundStyle(EditorTheme.tertiaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, EditorTheme.spaceSmall)
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .leading)
        .background(index == selectedIndex ? EditorTheme.tabActiveBackground : Color.clear)
        .contentShape(Rectangle())
        .helpIfSummary(suggestion.summary)
        .onHover { hovering in onHover(hovering, index) }
        .onTapGesture { onPick(index) }
        .pointerStyle(.link)
        .id(suggestion.id)
    }

    private func displayName(of suggestion: SuggestItem) -> String {
        guard let openToken, let closeToken else { return suggestion.name }
        return "\(openToken)\(suggestion.name)\(closeToken)"
    }

    private var footer: some View {
        Text("↑↓ Navigate   ↩ Insert   esc Dismiss")
            .font(EditorTheme.fontSmall)
            .foregroundStyle(EditorTheme.tertiaryText)
            .frame(maxWidth: .infinity, minHeight: Self.footerHeight, maxHeight: Self.footerHeight)
            .overlay(Divider(), alignment: .top)
    }
}

/// Drives the suggest panel for one text view: parses the fragment
/// under the caret, filters candidates, shows/positions a non-activating
/// panel anchored to the caret, and owns the interaction - arrow keys,
/// Return/Tab insert, Escape dismisses, mouse hovers/picks. Hosts bridge
/// this onto `EditorSuggestControlling` and feed candidate universes.
///
/// Two trigger modes, checked in order:
/// 1. **Trigger mode** - when `openToken` is set and the caret sits inside
///    an unclosed `openToken...` fragment (`{{name`); acceptance appends the
///    close token (swallowing an existing one).
/// 2. **Word mode** - the bare word at the caret; acceptance replaces it.
@MainActor
public final class SuggestController: NSObject {
    private struct Session: Equatable {
        let context: SuggestEngine.Context
        let matches: [SuggestItem]
        var selectedIndex: Int
        let isTriggerMode: Bool
    }

    private var candidates: [SuggestItem] = []
    private var wordCandidates: [SuggestItem]?
    private var session: Session?
    private weak var textView: NSTextView?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<SuggestPanel>?
    private var isWatchingDismissal = false
    private var mouseDownMonitor: Any?

    public var isVisible: Bool { session != nil }

    /// The open suggestion panel, if any. Editors that watch for
    /// click-outside-to-blur exempt popup picks.
    public var popupWindow: NSWindow? { panel }

    /// Host-declared trigger characters (Monaco's
    /// `CompletionItemProvider.triggerCharacters`): when the character just
    /// typed lands the caret right after one (e.g. `.`, `{`), the suggest
    /// panel opens over the word-mode universe with a zero-width fragment.
    /// nil/empty disables automatic triggering; `showSuggestions(at:)` stays
    /// available for host-declared contexts.
    public init(
        openToken: String? = nil, closeToken: String? = nil,
        triggerCharacters: Set<String> = []
    ) {
        self.openToken = openToken
        self.closeToken = closeToken
        self.triggerCharacters = triggerCharacters
        super.init()
    }

    private let openToken: String?
    private let closeToken: String?
    private let triggerCharacters: Set<String>

    // MARK: - Input from the editors

    /// Replaces the trigger-mode candidate universe and re-evaluates an
    /// open popup.
    public func setCandidates(_ candidates: [SuggestItem]) {
        self.candidates = candidates
        if session != nil, let textView {
            updateSession(for: textView, allowNewSession: false)
        }
    }

    /// Replaces the word-mode universe (nil disables the mode) and
    /// re-evaluates an open popup.
    public func setWordCandidates(_ candidates: [SuggestItem]?) {
        wordCandidates = candidates
        if session != nil, let textView {
            updateSession(for: textView, allowNewSession: false)
        }
    }

    /// The editor text changed: (re)evaluate the popup from scratch, then
    /// auto-trigger when the caret sits just after a trigger character with
    /// no word fragment (the `obj.` shape).
    public func textChanged(_ textView: NSTextView) {
        updateSession(for: textView, allowNewSession: true)
        guard !triggerCharacters.isEmpty, !isVisible,
            textView.isEditable, textView.selectedRange().length == 0,
            !textView.hasMarkedText()
        else { return }
        let caret = textView.selectedRange.location
        let ns = textView.string as NSString
        guard caret > 0, caret <= ns.length else { return }
        let previous = ns.substring(with: NSRange(location: caret - 1, length: 1))
        guard triggerCharacters.contains(previous),
            SuggestEngine.wordContext(atCaret: caret, in: textView.string) == nil
        else { return }
        showSuggestions(at: textView)
    }

    /// Explicitly opens the word-mode session at the caret (a host-declared
    /// trigger like `obj.` — a context word mode cannot infer). Ignores
    /// the call when the view can't complete (read-only, mid-IME, non-empty
    /// selection). The universe must be set via `setWordCandidates` first.
    public func showSuggestions(at textView: NSTextView) {
        guard textView.isEditable, textView.selectedRange().length == 0,
            !textView.hasMarkedText(), wordCandidates != nil
        else { return }
        let caret = textView.selectedRange.location
        // A zero-length context at the caret: the popup lists the whole
        // (already-filtered-by-the-host) universe, acceptance replaces the
        // bare word once the user keeps typing... but with no fragment the
        // replacement would insert at the caret. That matches `obj.`:
        // the host then filters per keystroke via setWordCandidates.
        let context = SuggestEngine.Context(
            fragmentRange: NSRange(location: caret, length: 0),
            fragment: "",
            trailingCloseRange: nil)
        resolveSession(context: context, isTriggerMode: false, candidates: wordCandidates ?? [])
    }

    /// Only the caret moved: keep an open popup glued to it, never open one
    /// from pure navigation.
    public func selectionChanged(_ textView: NSTextView) {
        guard session != nil else { return }
        updateSession(for: textView, allowNewSession: false)
    }

    // MARK: - Keyboard commands

    /// Handles the popup's key commands; true when consumed.
    @discardableResult
    public func handleCommand(_ selector: Selector) -> Bool {
        guard session != nil else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            return accept()
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
    }

    // MARK: - Session

    private func updateSession(for textView: NSTextView, allowNewSession: Bool) {
        self.textView = textView
        guard allowNewSession || session != nil else { return }
        guard
            textView.isEditable,
            textView.selectedRange().length == 0,
            !textView.hasMarkedText()
        else {
            hide()
            return
        }
        let caret = textView.selectedRange().location
        if let openToken, let closeToken,
            let context = SuggestEngine.triggerContext(
                atCaret: caret, in: textView.string, open: openToken, close: closeToken)
        {
            resolveSession(context: context, isTriggerMode: true, candidates: candidates)
        } else if let context = SuggestEngine.wordContext(atCaret: caret, in: textView.string),
            wordCandidates != nil
        {
            resolveSession(context: context, isTriggerMode: false, candidates: wordCandidates ?? [])
        } else {
            hide()
        }
    }

    private func resolveSession(
        context: SuggestEngine.Context, isTriggerMode: Bool, candidates: [SuggestItem]
    ) {
        let matches = SuggestEngine.suggestions(matching: context, from: candidates)
        guard !matches.isEmpty else {
            hide()
            return
        }
        let sameMatches = session?.matches == matches
        let selectedIndex = sameMatches ? min(session?.selectedIndex ?? 0, matches.count - 1) : 0
        let wasHidden = session == nil
        session = Session(
            context: context, matches: matches, selectedIndex: selectedIndex,
            isTriggerMode: isTriggerMode)
        if wasHidden || !sameMatches {
            refreshContent()
        } else {
            positionPanel()
        }
    }

    private func moveSelection(_ delta: Int) {
        guard var session, !session.matches.isEmpty else { return }
        session.selectedIndex =
            (session.selectedIndex + delta + session.matches.count) % session.matches.count
        self.session = session
    }

    /// Inserts the selected (or clicked) suggestion: trigger mode appends
    /// the close token (swallowing an existing one); word mode replaces the
    /// bare word with the name.
    @discardableResult
    public func accept(at index: Int? = nil) -> Bool {
        guard let session, let textView,
            session.matches.indices.contains(index ?? session.selectedIndex)
        else {
            hide()
            return false
        }
        let suggestion = session.matches[index ?? session.selectedIndex]
        let replacementRange = session.context.replacementRange
        hide()
        let inserted: String
        if session.isTriggerMode, let closeToken {
            inserted = "\(suggestion.name)\(closeToken)"
        } else {
            inserted = suggestion.name
        }
        // The standard editing path: registers undo, fires didChangeText,
        // and leaves the caret right after the inserted text.
        textView.insertText(inserted, replacementRange: replacementRange)
        return true
    }

    // MARK: - Panel

    private func refreshContent() {
        guard let session else { return }
        _ = ensurePanel()
        let showTokens = session.isTriggerMode
        hostingView?.rootView = SuggestPanel(
            suggestions: session.matches,
            selectedIndex: Binding(
                get: { [weak self] in self?.session?.selectedIndex ?? 0 },
                set: { [weak self] index in self?.session?.selectedIndex = index }
            ),
            onHover: { [weak self] hovering, index in
                self?.hoverRow(hovering, index: index)
            },
            onPick: { [weak self] index in
                self?.accept(at: index)
            },
            openToken: showTokens ? openToken : nil,
            closeToken: showTokens ? closeToken : nil)
        positionPanel()
    }

    private func hoverRow(_ hovering: Bool, index: Int) {
        // Only hover-enter moves the selection; hover-exit events (which the
        // re-render itself produces) must not undo it.
        guard hovering, let session, session.selectedIndex != index else { return }
        self.session?.selectedIndex = index
    }

    private func positionPanel() {
        guard let session, let textView, let window = textView.window else { return }
        let panel = ensurePanel()
        let height = listHeight(for: session.matches)
        guard let frame = anchoredFrame(for: textView, height: height) else {
            hide()
            return
        }
        panel.setFrame(frame, display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        registerDismissWatchers()
    }

    private func listHeight(for matches: [SuggestItem]) -> CGFloat {
        let rows =
            CGFloat(min(matches.count, SuggestPanel.maxVisibleRows))
            * SuggestPanel.rowHeight
        return rows + SuggestPanel.footerHeight
    }

    private func anchoredFrame(for textView: NSTextView, height: CGFloat) -> NSRect? {
        guard let window = textView.window, var caretRect = caretScreenRect(for: textView) else {
            return nil
        }
        if caretRect.isEmpty {
            let viewRect = textView.convert(textView.bounds, to: nil)
            caretRect = window.convertToScreen(viewRect)
        }
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.intersects(caretRect) }) ?? window.screen
        else { return nil }
        let visible = screen.visibleFrame
        let gap: CGFloat = 2
        let width = SuggestPanel.panelWidth
        var origin = NSPoint(x: caretRect.minX - 2, y: caretRect.minY - gap - height)
        if origin.y < visible.minY {
            let aboveY = caretRect.maxY + gap
            if aboveY + height <= visible.maxY {
                origin.y = aboveY
            } else {
                origin.y = max(visible.minY, min(origin.y, visible.maxY - height))
            }
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - width)
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }

    /// Screen-space rect of the caret's line, via the layout manager.
    private func caretScreenRect(for textView: NSTextView) -> NSRect? {
        guard
            let layoutManager = textView.layoutManager,
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
            width: 1,
            height: lineRect.height)
        return window.convertToScreen(textView.convert(viewRect, to: nil))
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: SuggestPanel.panelWidth, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.worksWhenModal = true
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        let hosting = NSHostingView(
            rootView: SuggestPanel(
                suggestions: [], selectedIndex: .constant(0),
                onHover: { _, _ in }, onPick: { _ in }))
        panel.contentView = hosting
        hostingView = hosting
        self.panel = panel
        return panel
    }

    // MARK: - Dismissal watchers

    /// While the popup is open: hide it when the app resigns active, and
    /// when a click lands anywhere except the popup itself and the editing
    /// text view.
    private func registerDismissWatchers() {
        guard !isWatchingDismissal else { return }
        isWatchingDismissal = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil)
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleClickOutside(event)
            }
            return event
        }
    }

    @objc private func appDidResignActive() {
        hide()
    }

    private func handleClickOutside(_ event: NSEvent) {
        guard let textView, session != nil else { return }
        if let panel, event.window === panel { return }
        let locationInEditor = textView.convert(event.locationInWindow, from: nil)
        if event.window === textView.window, textView.bounds.contains(locationInEditor) {
            return
        }
        hide()
    }

    public func hide() {
        session = nil
        if let panel {
            panel.orderOut(nil)
            panel.parent?.removeChildWindow(panel)
        }
        if isWatchingDismissal {
            isWatchingDismissal = false
            NotificationCenter.default.removeObserver(
                self,
                name: NSApplication.didResignActiveNotification,
                object: nil)
        }
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
            self.mouseDownMonitor = nil
        }
    }

}

extension View {
    /// Attaches the summary tooltip only when one exists (an empty `help`
    /// renders a blank tooltip).
    @ViewBuilder
    fileprivate func helpIfSummary(_ summary: String?) -> some View {
        if let summary {
            self.help(summary)
        } else {
            self
        }
    }
}
