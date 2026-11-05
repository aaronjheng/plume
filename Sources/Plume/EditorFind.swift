import AppKit
import SwiftUI

/// The editor's find/replace state, owned by SwiftUI and mirrored into the
/// coordinator on every update. `Equatable` so updateNSView can diff.
struct EditorFindState: Equatable {
    var visible = false
    var replacing = false
    var query = ""
    var replacement = ""
    var caseSensitive = false
    /// Match a regular expression (Monaco find's `.*` toggle). In regex
    /// mode the replacement carries `$1`-style capture templates.
    var isRegex = false
    /// Whole-word matches only (Monaco find's `ab` toggle): neither
    /// neighbor of a match may be a word character.
    var wholeWord = false
    /// Shape the replacement's case after each match (Monaco's `AB`
    /// toggle; literal mode only - regex replacements carry templates).
    var preserveCase = false
    /// Scope matches to the captured selection.
    var inSelection = false
    /// Captured scope (UTF-16 offsets into the document).
    var scopeLocation = 0
    var scopeLength = 0
}

/// Buttons/fields dispatch through this: the SwiftUI side sets a pending
/// action, updateNSView performs it on the coordinator and clears it (the
/// same deferred-action pattern as the method dropdown's pending pick).
enum EditorFindAction {
    case next
    case previous
    case replaceCurrent
    case replaceAll
    case toggleInSelection
}

/// AppKit → SwiftUI callbacks: ⌘F opening the bar (with the selection as
/// the prefill and whether the replace row shows), match count/index
/// updates, Esc closing the bar.
struct EditorFindHooks {
    let requested: (String?, NSRange?, Bool) -> Void
    let countChanged: (Int, Int?) -> Void
    let closed: () -> Void
    /// ⌥⌘E: adopt the selection as the find query (bar stays closed).
    let useSelection: (String) -> Void
    /// ⌥⌘L: open the go-to-line panel.
    let linePanel: () -> Void
}

/// The find/replace bar overlaid across the editor's top-right corner
/// (Xcode-style): fields stacked left, controls right, with a replace row
/// behind the toggle. Pure presentation - actions are handed back out.
struct EditorFindBar: View {
    @Binding var query: String
    @Binding var replacement: String
    @Binding var caseSensitive: Bool
    @Binding var isRegex: Bool
    @Binding var wholeWord: Bool
    @Binding var preserveCase: Bool
    @Binding var replacing: Bool
    let matchCount: Int
    let matchIndex: Int?
    let isEditable: Bool
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onReplace: () -> Void
    let onReplaceAll: () -> Void
    let onClose: () -> Void

    @FocusState private var findFocused: Bool
    @FocusState private var replaceFocused: Bool

    private let fieldWidth: CGFloat = 300
    /// The match count's fixed slot (Monaco: `MAX_MATCHES_COUNT_WIDTH`,
    /// 69px) - reserved so the widget never shifts as the label changes.
    private let countWidth: CGFloat = 68

    /// The widget card's size, MIRRORED from `body`'s fixed layout:
    /// chevron(20) + field(300) + count(68) + three 20pt buttons at
    /// spaceXSmall gaps, plus the card's spaceSmall padding - and the
    /// replace row (26pt field + 6pt gap) when toggled.
    /// `EditorRepresentable.updateNSView` places the cursor exclusion from
    /// this (no SwiftUI measurement round-trip); keep the two in sync.
    static func cardSize(replacing: Bool) -> CGSize {
        let row: CGFloat = 20 + 4 + 300 + 4 + 68 + 4 + 20 + 4 + 20 + 4 + 20
        let contentHeight: CGFloat = replacing ? 26 + 6 + 26 : 26
        return CGSize(
            width: row + 2 * EditorTheme.spaceSmall,
            height: contentHeight + 2 * EditorTheme.spaceSmall)
    }

    var body: some View {
        HStack(alignment: .center, spacing: EditorTheme.spaceXSmall) {
            // Monaco's Toggle Replace (`.button.toggle`) sits at the
            // widget's leading edge - a chevron that points right while the
            // replace row is collapsed and down while it is open.
            hoverButton(
                "Toggle Replace", isActive: replacing,
                help: replacing ? "Hide Replace" : "Show Replace",
                systemImage: replacing ? "chevron.down" : "chevron.right"
            ) {
                replacing.toggle()
            }
            VStack(alignment: .leading, spacing: 6) {
                // Monaco's find-part order: input (with the option toggles
                // nested inside its trailing edge), match count,
                // previous/next, then close. Nothing sits between the input
                // and its toggles, so there is no dead middle in the bar.
                HStack(spacing: EditorTheme.spaceXSmall) {
                    findField
                    countLabel
                        .frame(width: countWidth, alignment: .trailing)
                    hoverButton(
                        "Previous match", isActive: false, help: "Previous (Shift-Return)",
                        disabled: matchCount == 0, systemImage: "chevron.up", action: onPrevious)
                    hoverButton(
                        "Next match", isActive: false, help: "Next (Return)",
                        disabled: matchCount == 0, systemImage: "chevron.down", action: onNext)
                    hoverButton(
                        "Close find bar", isActive: false, help: "Close (Esc)",
                        systemImage: "xmark", action: onClose)
                }
                // Monaco's replace-part: the replace input (with `AB`
                // nested inside) then Replace / Replace All, starting at
                // the same x as the find row's count because both inputs
                // share a width.
                if replacing {
                    HStack(spacing: EditorTheme.spaceXSmall) {
                        replaceField
                        Button("Replace", action: onReplace)
                            .buttonStyle(EditorSecondaryButtonStyle(minHeight: 24))
                            .disabled(!isEditable || matchCount == 0)
                            .help("Replace current match (⌘⌥F)")
                        Button("All", action: onReplaceAll)
                            .buttonStyle(EditorSecondaryButtonStyle(minHeight: 24))
                            .disabled(!isEditable || matchCount == 0)
                            .help("Replace all matches (⌘⌥⇧F)")
                    }
                }
            }
        }
        .padding(EditorTheme.spaceSmall)
        .background(
            RoundedRectangle(cornerRadius: EditorTheme.radiusMedium, style: .continuous)
                .fill(EditorTheme.controlBackground)
                .shadow(color: EditorTheme.popupShadow, radius: 10, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: EditorTheme.radiusMedium, style: .continuous)
                .strokeBorder(EditorTheme.border, lineWidth: EditorTheme.lineField)
        )
        .onAppear {
            // Focus after the field is actually in a window - a same-tick
            // FocusState write races the overlay's first layout.
            DispatchQueue.main.async { findFocused = true }
        }
        .onChange(of: replacing) { _, on in
            DispatchQueue.main.async {
                if on {
                    replaceFocused = true
                } else {
                    findFocused = true
                }
            }
        }
    }

    private var findField: some View {
        field(text: $query, prompt: "Find", focused: findFocused) {
            HStack(spacing: 2) {
                hoverButton("Aa", isActive: caseSensitive, help: "Match Case") {
                    caseSensitive.toggle()
                }
                hoverButton("ab", isActive: wholeWord, help: "Match Whole Word") {
                    wholeWord.toggle()
                }
                hoverButton(".*", isActive: isRegex, help: "Use Regular Expression ($1 in replacement)") {
                    isRegex.toggle()
                }
            }
        }
        .focused($findFocused)
        .onSubmit(onNext)
        .onExitCommand { onClose() }
    }

    private var replaceField: some View {
        field(text: $replacement, prompt: "Replace with", focused: replaceFocused) {
            hoverButton("AB", isActive: preserveCase, help: "Preserve Case (literal mode)") {
                preserveCase.toggle()
            }
        }
        .focused($replaceFocused)
        .onSubmit(onReplace)
        .onExitCommand { onClose() }
    }

    /// One input of the bar: the text field with its option toggles as
    /// SIBLINGS inside the bordered box (Monaco's `.monaco-findInput` is
    /// the inputbox plus its `.controls`). Siblings rather than an overlay
    /// on the field: an `NSTextField`-backed view keeps its own cursor
    /// over its whole bounds, so an overlay's pointer style never applies
    /// and its buttons stay stuck on the arrow cursor.
    private func field<Accessory: View>(
        text: Binding<String>,
        prompt: String,
        focused: Bool,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 2) {
            TextField(prompt, text: text)
                .font(EditorTheme.fontMonoSubheadline)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .padding(.leading, EditorTheme.spaceCompact)
            accessory()
                .padding(.trailing, EditorTheme.spaceCompact)
        }
        .frame(width: fieldWidth, height: 26)
        .background(
            RoundedRectangle(cornerRadius: EditorTheme.radiusSmall, style: .continuous)
                .fill(EditorTheme.fieldBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: EditorTheme.radiusSmall, style: .continuous)
                .strokeBorder(
                    focused ? EditorTheme.accent : EditorTheme.border,
                    lineWidth: focused ? EditorTheme.lineFocusedField : EditorTheme.lineField
                )
        )
    }

    /// Monaco always renders a count label - `No results` when nothing
    /// matches - so the reserved slot is never an empty hole, and its fixed
    /// width keeps the widget from shifting as the label changes. The
    /// error tint applies only once a query exists (`no-results`), not to
    /// the untouched state.
    @ViewBuilder
    private var countLabel: some View {
        if matchCount == 0 {
            Text("No results")
                .font(EditorTheme.fontSmall)
                .foregroundStyle(query.isEmpty ? EditorTheme.textSecondary : EditorTheme.error)
        } else {
            // Monaco's label is `NLS_MATCHES_LOCATION` = "{0} of {1}",
            // with "?" standing in for the position while no match is
            // current (`matchesPosition === '0'`).
            Text("\(matchIndex.map { String($0 + 1) } ?? "?") of \(matchCount)")
                .font(EditorTheme.fontSmall.monospacedDigit())
                .foregroundStyle(EditorTheme.textSecondary)
        }
    }

    /// The bar's quiet square button (Aa, ab, .*, chevrons): hover fill,
    /// on-state accent tint, disabled dim - the shared icon-button language.
    /// `systemImage` renders a real glyph (the chevrons); otherwise the
    /// label is drawn as text (the find-option toggles).
    /// One icon button of the bar. The chip chrome (20pt frame, checked
    /// fill + border, hover fill) and the pointer style both live in
    /// `EditorIconButtonStyle` - see its note on why the cursor cannot be
    /// attached to the `Button` here.
    private func hoverButton(
        _ label: String,
        isActive: Bool,
        help: String,
        disabled: Bool = false,
        systemImage: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(EditorTheme.fontIconCompact)
            } else {
                Text(label)
                    .font(EditorTheme.fontSmall.weight(isActive ? .semibold : .regular))
            }
        }
        .buttonStyle(EditorIconButtonStyle(isActive: isActive))
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(label)
    }
}

/// The go-to-line mini panel (⌥⌘L): a number field and a Go button,
/// matching the find bar's overlay language. Accepts `line` or
/// `line:column` (Monaco's quick-input format); the column is clamped to
/// the line's content.
struct EditorGoToLineBar: View {
    @Binding var text: String
    let lineCount: Int
    let onClose: () -> Void
    let onSubmit: () -> Void

    @FocusState private var focused: Bool

    /// Parses `12` or `12:5`; nil when the field is not (yet) valid.
    static func parse(_ text: String) -> (line: Int, column: Int?)? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard let first = parts.first, let line = Int(first), line > 0 else { return nil }
        if parts.count == 2 {
            guard let column = Int(parts[1]), column > 0 else { return nil }
            return (line, column)
        }
        guard parts.count == 1 else { return nil }
        return (line, nil)
    }

    /// The panel card's size, MIRRORED from `body` (label + 110pt field +
    /// Go button, spaceXSmall gaps, spaceSmall card padding), with a
    /// generous width since the Go button's is text-driven. Used by
    /// `EditorRepresentable.updateNSView` for the cursor exclusion; keep
    /// the two in sync.
    static func cardSize() -> CGSize {
        CGSize(width: 240, height: 26 + 2 * EditorTheme.spaceSmall)
    }

    var body: some View {
        HStack(spacing: EditorTheme.spaceXSmall) {
            Text("Line")
                .font(EditorTheme.fontSmall)
                .foregroundStyle(EditorTheme.textSecondary)
            TextField("1–\(max(lineCount, 1))", text: $text)
                .font(EditorTheme.fontMonoSubheadline)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .focused($focused)
                .onSubmit(onSubmit)
                .onExitCommand { onClose() }
                .onChange(of: text) { _, newValue in
                    // Digits plus at most one colon (after a digit): the
                    // Monaco quick-input shape.
                    var filtered = ""
                    var seenColon = false
                    for character in newValue {
                        if character.isNumber {
                            filtered.append(character)
                        } else if character == ":", !seenColon, !filtered.isEmpty {
                            seenColon = true
                            filtered.append(character)
                        }
                    }
                    if filtered != newValue { text = filtered }
                }
                .padding(.horizontal, EditorTheme.spaceCompact)
                .frame(width: 110, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: EditorTheme.radiusSmall, style: .continuous)
                        .fill(EditorTheme.fieldBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: EditorTheme.radiusSmall, style: .continuous)
                        .strokeBorder(
                            (text.isEmpty || Self.parse(text) != nil)
                                ? EditorTheme.accent : EditorTheme.error,
                            lineWidth: EditorTheme.lineFocusedField
                        )
                )
                .help("Line, or line:column (e.g. 12:5)")
            Button("Go", action: onSubmit)
                .buttonStyle(EditorSecondaryButtonStyle(minHeight: 24))
        }
        .padding(EditorTheme.spaceSmall)
        .background(
            RoundedRectangle(cornerRadius: EditorTheme.radiusMedium, style: .continuous)
                .fill(EditorTheme.controlBackground)
                .shadow(color: EditorTheme.popupShadow, radius: 10, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: EditorTheme.radiusMedium, style: .continuous)
                .strokeBorder(EditorTheme.border, lineWidth: EditorTheme.lineField)
        )
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
    }
}

// MARK: - Coordinator machinery

extension EditorCoordinator {
    /// Diffs the find state pushed from SwiftUI: recompute + highlight when
    /// the query/case/visibility changed, clear when closed.
    func syncFindState(_ state: EditorFindState, in textView: NSTextView) {
        guard state != lastFindState else { return }
        let wasVisible = lastFindState?.visible ?? false
        lastFindState = state
        guard state.visible else {
            if wasVisible || !findMatches.isEmpty { clearFind(in: textView) }
            return
        }
        refreshFindHighlights(
            in: textView, selectFirstAfterCaret: parent.findCursorMoveOnType)
    }

    func refreshFindHighlights(in textView: NSTextView) {
        refreshFindHighlights(in: textView, selectFirstAfterCaret: false)
    }

    private func refreshFindHighlights(in textView: NSTextView, selectFirstAfterCaret: Bool) {
        let state = parent.find
        guard state.visible, !state.query.isEmpty else {
            clearFind(in: textView)
            return
        }
        findMatches = Self.scopedFindMatches(in: textView.string, state: state)
        let caret = textView.selectedRange().location
        if selectFirstAfterCaret {
            // Query changed: select the first match at/after the caret
            // (wrapping to the first match), like Xcode.
            findCurrentIndex =
                findMatches.firstIndex(where: { NSMaxRange($0) > caret })
                ?? (findMatches.isEmpty ? nil : 0)
            if let index = findCurrentIndex {
                textView.setSelectedRange(findMatches[index])
                textView.scrollRangeToVisible(findMatches[index])
            }
        } else {
            // An edit in the editor: keep the index on the first match
            // ending at/after the caret so the count stays meaningful.
            findCurrentIndex =
                findMatches.firstIndex(where: { NSMaxRange($0) > caret })
                ?? (findMatches.isEmpty ? nil : findMatches.count - 1)
        }
        applyFindHighlights(in: textView)
        parent.findHooks?.countChanged(findMatches.count, findCurrentIndex)
    }

    private func clearFind(in textView: NSTextView) {
        findMatches = []
        findCurrentIndex = nil
        let length = (textView.string as NSString).length
        textView.layoutManager?.removeTemporaryAttribute(
            .backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
        parent.findHooks?.countChanged(0, nil)
        rootView?.rulerView?.needsDisplay = true
    }

    private func applyFindHighlights(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        layoutManager.removeTemporaryAttribute(
            .backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
        guard !findMatches.isEmpty else { return }
        // Temporary background attributes overlay the storage tints (and
        // drop automatically on edits - the pipeline re-runs this after).
        let wash = NSColor(EditorTheme.warning).withAlphaComponent(0.28)
        let currentWash = NSColor(EditorTheme.warning).withAlphaComponent(0.48)
        for (index, range) in findMatches.enumerated() {
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: index == findCurrentIndex ? currentWash : wash,
                forCharacterRange: range)
        }
        rootView?.rulerView?.needsDisplay = true
    }

    /// Scoped to the captured selection when `inSelection` is on,
    /// otherwise the whole document.
    static func scopedFindMatches(in text: String, state: EditorFindState) -> [NSRange] {
        guard !state.query.isEmpty else { return [] }
        let ns = text as NSString
        guard state.inSelection, state.scopeLength > 0 else {
            return findMatches(
                in: text, query: state.query, caseSensitive: state.caseSensitive,
                isRegex: state.isRegex, wholeWord: state.wholeWord)
        }
        let scope = NSRange(
            location: min(max(state.scopeLocation, 0), ns.length),
            length: min(
                state.scopeLength,
                max(0, ns.length - min(max(state.scopeLocation, 0), ns.length))))
        guard scope.length > 0 else { return [] }
        let substring = ns.substring(with: scope)
        return findMatches(
            in: substring, query: state.query, caseSensitive: state.caseSensitive,
            isRegex: state.isRegex, wholeWord: state.wholeWord
        )
        .map { NSRange(location: $0.location + scope.location, length: $0.length) }
    }

    /// All occurrences of `query`, non-overlapping, in order. Literal
    /// mode scans with NSString; regex mode enumerates
    /// `NSRegularExpression` matches (nil pattern = no matches, the bar's
    /// count reads "No results"). `wholeWord` filters both modes by the
    /// neighbors' word-character status.
    static func findMatches(
        in text: String, query: String, caseSensitive: Bool, isRegex: Bool, wholeWord: Bool
    ) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let ns = text as NSString
        var ranges: [NSRange] = []
        let length = ns.length
        if isRegex {
            guard
                let regex = try? NSRegularExpression(
                    pattern: query,
                    options: caseSensitive ? [] : [.caseInsensitive])
            else { return [] }
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: length)) { match, _, _ in
                guard let match else { return }
                if !wholeWord || Self.isWholeWord(ns, match.range) {
                    ranges.append(match.range)
                }
            }
            return ranges
        }
        var searchRange = NSRange(location: 0, length: length)
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        while searchRange.length > 0 {
            let found = ns.range(of: query, options: options, range: searchRange)
            guard found.location != NSNotFound else { break }
            if !wholeWord || Self.isWholeWord(ns, found) {
                ranges.append(found)
            }
            searchRange.location = NSMaxRange(found)
            searchRange.length = length - searchRange.location
        }
        return ranges
    }

    /// Neither neighbor of `range` may be a word character (letters,
    /// digits, underscore).
    private static func isWholeWord(_ text: NSString, _ range: NSRange) -> Bool {
        let beforeClean =
            range.location == 0
            || !isWordChar(codeEditorChar(text, range.location - 1))
        let afterClean =
            NSMaxRange(range) >= text.length
            || !isWordChar(codeEditorChar(text, NSMaxRange(range)))
        return beforeClean && afterClean
    }

    /// Shapes `replacement` after `matched`'s case (Monaco's preserve
    /// case): all-uppercase match -> uppercase replacement, capitalized
    /// match -> capitalized replacement, otherwise as typed.
    static func preservingCase(_ matched: String, _ replacement: String) -> String {
        guard !matched.isEmpty, !replacement.isEmpty else { return replacement }
        if matched == matched.uppercased(), matched != matched.lowercased() {
            return replacement.uppercased()
        }
        if let first = matched.first, first.isUppercase,
            matched.dropFirst() == matched.dropFirst().lowercased()
        {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    /// The replacement for one match: regex mode templates `$1` against
    /// the pre-edit text; literal mode honors preserve case.
    static func replacementText(
        for range: NSRange, in text: String, state: EditorFindState
    ) -> String {
        let ns = text as NSString
        guard ns.length >= NSMaxRange(range) else { return state.replacement }
        if state.isRegex,
            let regex = try? NSRegularExpression(
                pattern: state.query,
                options: state.caseSensitive ? [] : [.caseInsensitive])
        {
            guard let match = regex.firstMatch(in: text, range: range) else {
                return state.replacement
            }
            return regex.replacementString(for: match, in: text, offset: 0, template: state.replacement)
        }
        guard state.preserveCase else { return state.replacement }
        return preservingCase(ns.substring(with: range), state.replacement)
    }

    func performFindAction(_ action: EditorFindAction, in textView: NSTextView) {
        switch action {
        case .next: findNext(in: textView)
        case .previous: findPrevious(in: textView)
        case .replaceCurrent: replaceCurrent(in: textView)
        case .replaceAll: replaceAll(in: textView)
        case .toggleInSelection: toggleFindInSelection(in: textView)
        }
    }

    func findNext(in textView: NSTextView) {
        guard !findMatches.isEmpty else { return }
        let current = findCurrentIndex ?? -1
        let next: Int
        if parent.findLoops {
            next = (current + 1) % findMatches.count
        } else {
            next = min(current + 1, findMatches.count - 1)
        }
        findCurrentIndex = next
        applyFindHighlights(in: textView)
        textView.setSelectedRange(findMatches[next])
        textView.scrollRangeToVisible(findMatches[next])
        parent.findHooks?.countChanged(findMatches.count, next)
    }

    func findPrevious(in textView: NSTextView) {
        guard !findMatches.isEmpty else { return }
        let current = findCurrentIndex ?? findMatches.count
        let previous: Int
        if parent.findLoops {
            previous = (current - 1 + findMatches.count) % findMatches.count
        } else {
            previous = max(current - 1, 0)
        }
        findCurrentIndex = previous
        applyFindHighlights(in: textView)
        textView.setSelectedRange(findMatches[previous])
        textView.scrollRangeToVisible(findMatches[previous])
        parent.findHooks?.countChanged(findMatches.count, previous)
    }

    func replaceCurrent(in textView: NSTextView) {
        guard textView.isEditable, let index = findCurrentIndex, index < findMatches.count else { return }
        let range = findMatches[index]
        let replacement = Self.replacementText(
            for: range, in: textView.string, state: parent.find)
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        // processEditing refreshed the matches; the index now points at the
        // first match at/after the replacement, so Replace walks forward.
        if let index = findCurrentIndex, index < findMatches.count {
            textView.setSelectedRange(findMatches[index])
            textView.scrollRangeToVisible(findMatches[index])
            applyFindHighlights(in: textView)
        }
        parent.findHooks?.countChanged(findMatches.count, findCurrentIndex)
    }

    func replaceAll(in textView: NSTextView) {
        guard textView.isEditable, !findMatches.isEmpty else { return }
        let state = parent.find
        let original = textView.string
        // Capture-templates resolve against the pre-edit text, so every
        // replacement is computed before the first storage edit.
        let replacements = findMatches.map { Self.replacementText(for: $0, in: original, state: state) }
        let undoManager = textView.undoManager
        undoManager?.beginUndoGrouping()
        for (index, range) in findMatches.reversed().enumerated() {
            let replacement = replacements[findMatches.count - 1 - index]
            guard textView.shouldChangeText(in: range, replacementString: replacement) else { continue }
            textView.textStorage?.replaceCharacters(in: range, with: replacement)
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Replace All")
        textView.didChangeText()
        if let first = findMatches.first {
            textView.setSelectedRange(first)
            textView.scrollRangeToVisible(first)
        }
        parent.findHooks?.countChanged(findMatches.count, findCurrentIndex)
    }

    /// ⌘F: opens the bar, prefilling the query with the selection (per
    /// `seedSearchStringFromSelection`); scope optional per
    /// `autoFindInSelection`.
    func requestFind(replaceMode: Bool, in textView: NSTextView) {
        let selection = textView.selectedRange()
        var selectedText: String?
        switch parent.seedSearchStringFromSelection {
        case .never:
            selectedText = nil
        case .always:
            if selection.length > 0, selection.length <= 200 {
                selectedText = (textView.string as NSString).substring(with: selection)
            }
        case .selection:
            if selection.length > 0, selection.length <= 200 {
                let substring = (textView.string as NSString).substring(with: selection)
                if !substring.contains("\n") { selectedText = substring }
            }
        }
        let scope: NSRange?
        switch parent.autoFindInSelection {
        case .never:
            scope = nil
        case .always:
            scope = selection.length > 0 ? selection : nil
        case .multiline:
            let substring =
                selection.length > 0
                ? (textView.string as NSString).substring(with: selection) : ""
            scope = substring.contains("\n") ? selection : nil
        }
        parent.findHooks?.requested(selectedText, scope, replaceMode)
    }

    /// ⌥⌘G: toggle find-in-selection, capturing the live selection.
    func toggleFindInSelection(in textView: NSTextView) {
        let selection = textView.selectedRange()
        let query = parent.find.query
        parent.findHooks?.requested(
            query.isEmpty ? nil : query,
            selection.length > 0 ? selection : nil,
            parent.find.replacing)
    }

    func closeFind(in textView: NSTextView) {
        parent.findHooks?.closed()
        clearFind(in: textView)
    }
}
