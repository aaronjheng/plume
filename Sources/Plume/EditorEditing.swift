import AppKit

// MARK: - Line operations

extension EditorCoordinator {
    /// ⌘D: duplicates the selection's lines right below, selecting the copy.
    func duplicateLines(in textView: NSTextView) {
        guard textView.isEditable, !textView.hasMarkedText(),
            let selected = selectedBlock(textView.string as NSString, selection: textView.selectedRange),
            let currentText = textView.string as NSString?
        else { return }
        let insertLocation = NSMaxRange(selected.range)
        // After the block's last line: `block + \n` normally, `\n + block`
        // at the very end of the document (no newline to lean on there).
        let atEnd = insertLocation >= currentText.length
        let inserted = atEnd ? "\n" + selected.block : selected.block + "\n"
        replace(
            in: textView,
            range: NSRange(location: insertLocation, length: 0),
            with: inserted,
            caret: NSMaxRange(selected.range))
        // Select the copy, like every editor's duplicate.
        let copyStart = atEnd ? insertLocation + 1 : insertLocation
        textView.setSelectedRange(NSRange(location: copyStart, length: (selected.block as NSString).length))
    }

    /// ⌘⇧K: deletes the selection's lines, newline included, so no blank
    /// line is left behind (at the end of the document the preceding
    /// newline goes instead).
    func deleteLines(in textView: NSTextView) {
        guard textView.isEditable, !textView.hasMarkedText(),
            let selected = selectedBlock(textView.string as NSString, selection: textView.selectedRange)
        else { return }
        var range = NSRange(location: selected.range.location, length: selected.range.length + 1)
        if NSMaxRange(range) > (textView.string as NSString).length {
            // Last line: eat the preceding newline instead.
            range = NSRange(location: selected.range.location - 1, length: selected.range.length + 1)
        }
        guard range.location >= 0 else { return }
        replace(in: textView, range: range, with: "", caret: range.location)
    }

    /// ⌃⌘↑ / ⌃⌘↓: moves the selection's lines one line up/down, keeping
    /// the selection on the moved block.
    func moveLines(in textView: NSTextView, up: Bool) {
        guard textView.isEditable, !textView.hasMarkedText(),
            let selected = selectedBlock(textView.string as NSString, selection: textView.selectedRange)
        else { return }
        let text = textView.string as NSString
        if up {
            guard selected.range.location > 0 else { return }
            // The line above spans up to the newline just before the block.
            let aboveRange = text.lineRange(for: NSRange(location: selected.range.location - 1, length: 0))
            let above = text.substring(with: NSRange(location: aboveRange.location, length: aboveRange.length - 1))
            let span = NSRange(
                location: aboveRange.location,
                length: NSMaxRange(selected.range) - aboveRange.location)
            replace(
                in: textView,
                range: span,
                with: selected.block + "\n" + above,
                caret: span.location)
            textView.setSelectedRange(
                NSRange(
                    location: selected.range.location - aboveRange.length,
                    length: selected.range.length))
        } else {
            // The newline separating the block from the line below belongs
            // to the block in this swap; a block at the end of the document
            // cannot move down.
            guard NSMaxRange(selected.range) < text.length,
                char(text, NSMaxRange(selected.range)) == "\n"
            else { return }
            let belowRange = text.lineRange(
                for: NSRange(location: NSMaxRange(selected.range) + 1, length: 0))
            let belowEnd =
                belowRange.length > 0
                ? NSMaxRange(belowRange) - (char(text, NSMaxRange(belowRange) - 1) == "\n" ? 1 : 0)
                : belowRange.location
            let below = text.substring(with: NSRange(location: belowRange.location, length: belowEnd - belowRange.location))
            let span = NSRange(location: selected.range.location, length: belowEnd - selected.range.location)
            replace(
                in: textView,
                range: span,
                with: below + "\n" + selected.block,
                caret: span.location)
            textView.setSelectedRange(
                NSRange(
                    location: selected.range.location + below.count + 1,
                    length: selected.range.length))
        }
    }

    /// ⌥⇧↑ / ⌥⇧↓: copies the selection's lines above/below, keeping the
    /// selection on the original block (copy-down: original stays put;
    /// copy-up: original shifts down by the copy height).
    func copyLines(in textView: NSTextView, up: Bool) {
        guard textView.isEditable, !textView.hasMarkedText(),
            let selected = selectedBlock(textView.string as NSString, selection: textView.selectedRange)
        else { return }
        let text = textView.string as NSString
        if up {
            // Insert `block + \n` at the block start; the original block
            // is pushed down by the copy height, so the selection follows
            // it there.
            let copyHeight = (selected.block as NSString).length + 1
            replace(
                in: textView,
                range: NSRange(location: selected.range.location, length: 0),
                with: selected.block + "\n",
                caret: selected.range.location + copyHeight)
            textView.setSelectedRange(
                NSRange(
                    location: selected.range.location + copyHeight,
                    length: selected.range.length))
        } else {
            let insertLocation = NSMaxRange(selected.range)
            let atEnd = insertLocation >= text.length
            let inserted = atEnd ? "\n" + selected.block : selected.block + "\n"
            replace(
                in: textView,
                range: NSRange(location: insertLocation, length: 0),
                with: inserted,
                caret: selected.range.location)
            // Selection stays on the original block (unchanged offset).
            textView.setSelectedRange(selected.range)
        }
    }

    /// ⌃T: swaps the characters before and after the caret (Monaco
    /// `transposeChars`). At the document end the last two swap; at the
    /// start nothing swaps. Skips surrogate halves and selections.
    func transposeCharacters(in textView: NSTextView) {
        guard textView.isEditable, !textView.hasMarkedText(),
            textView.selectedRange().length == 0
        else { return }
        let ns = textView.string as NSString
        let caret = textView.selectedRange().location
        guard ns.length >= 2 else { return }
        let swapAt: Int
        if caret <= 0 {
            return
        } else if caret >= ns.length {
            swapAt = ns.length - 2
        } else {
            swapAt = caret - 1
        }
        guard swapAt >= 0, swapAt + 1 < ns.length else { return }
        let isSurrogate: (unichar) -> Bool = { $0 >= 0xD800 && $0 <= 0xDFFF }
        let unitA = ns.character(at: swapAt)
        let unitB = ns.character(at: swapAt + 1)
        if isSurrogate(unitA) || isSurrogate(unitB) { return }
        let first = ns.substring(with: NSRange(location: swapAt, length: 1))
        let second = ns.substring(with: NSRange(location: swapAt + 1, length: 1))
        guard first != second else { return }
        replace(
            in: textView,
            range: NSRange(location: swapAt, length: 2),
            with: second + first,
            caret: min(swapAt + 2, ns.length))
    }
}

// MARK: - Line transforms

extension EditorCoordinator {
    /// Applies `transform` over the selection's lines in place, keeping
    /// the block selected.
    func transformLines(in textView: NSTextView, transform: (String) -> String) {
        guard textView.isEditable, !textView.hasMarkedText(),
            let selected = selectedBlock(textView.string as NSString, selection: textView.selectedRange)
        else { return }
        let transformed = transform(selected.block)
        guard transformed != selected.block else { return }
        replace(
            in: textView,
            range: selected.range,
            with: transformed,
            caret: selected.range.location)
        textView.setSelectedRange(
            NSRange(location: selected.range.location, length: (transformed as NSString).length))
    }

    func uppercaseLines(in textView: NSTextView) {
        transformLines(in: textView) { $0.uppercased() }
    }

    func lowercaseLines(in textView: NSTextView) {
        transformLines(in: textView) { $0.lowercased() }
    }

    /// Sorts the selection's lines (locale-aware);
    /// the selection stays on the sorted block.
    func sortLines(in textView: NSTextView, descending: Bool) {
        guard textView.isEditable, !textView.hasMarkedText(),
            let selected = selectedBlock(textView.string as NSString, selection: textView.selectedRange)
        else { return }
        let lines = selected.block.components(separatedBy: "\n")
        let sorted = lines.sorted {
            descending
                ? $0.localizedStandardCompare($1) == .orderedDescending
                : $0.localizedStandardCompare($1) == .orderedAscending
        }
        let result = sorted.joined(separator: "\n")
        guard result != selected.block else { return }
        replace(
            in: textView,
            range: selected.range,
            with: result,
            caret: selected.range.location)
        textView.setSelectedRange(
            NSRange(location: selected.range.location, length: (result as NSString).length))
    }

    /// Strips trailing spaces/tabs from every line of the document
    /// as one undoable step.
    func trimTrailingWhitespace(in textView: NSTextView) {
        guard textView.isEditable, !textView.hasMarkedText() else { return }
        let text = textView.string
        guard
            let regex = try? NSRegularExpression(
                pattern: "[ \\t]+$", options: [.anchorsMatchLines])
        else { return }
        let full = NSRange(location: 0, length: (text as NSString).length)
        guard regex.firstMatch(in: text, range: full) != nil else { return }
        let trimmed = regex.stringByReplacingMatches(
            in: text, range: full, withTemplate: "")
        replace(
            in: textView,
            range: full,
            with: trimmed,
            caret: min(textView.selectedRange().location, (trimmed as NSString).length))
    }

    /// Joins the selection's lines with single spaces;
    /// each seam's surrounding whitespace collapses to one space.
    func joinLines(in textView: NSTextView) {
        guard textView.isEditable, !textView.hasMarkedText(),
            let selected = selectedBlock(textView.string as NSString, selection: textView.selectedRange)
        else { return }
        let lines = selected.block.components(separatedBy: "\n")
        guard lines.count > 1 else { return }
        let joined =
            lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        guard joined != selected.block else { return }
        replace(
            in: textView,
            range: selected.range,
            with: joined,
            caret: selected.range.location + (joined as NSString).length)
    }
}

// MARK: - Bracket matching

extension EditorCoordinator {
    /// Highlights the bracket pair around the caret: the character before
    /// the caret wins, then the character at it. Temporary foreground
    /// attributes (edits drop them; the next selection change reapplies).
    func updateBracketHighlight(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        for range in bracketHighlightRanges {
            let valid = range.intersection(length)
            guard valid.length > 0 else { continue }
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: valid)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: valid)
        }
        bracketHighlightRanges = []
        guard textView.selectedRange().length == 0 else { return }
        let text = textView.string as NSString
        let caret = textView.selectedRange().location
        var anchor: Int?
        if caret > 0, Self.isBracket(codeEditorChar(text, caret - 1)) {
            anchor = caret - 1
        } else if caret < length, Self.isBracket(codeEditorChar(text, caret)) {
            anchor = caret
        }
        guard let anchor, let match = bracketMatch(in: text, at: anchor) else { return }
        bracketHighlightRanges = [
            NSRange(location: anchor, length: 1),
            NSRange(location: match, length: 1),
        ]
        for range in bracketHighlightRanges {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor(EditorTheme.accent), forCharacterRange: range)
            if parent.renderBracketPairHighlight {
                layoutManager.addTemporaryAttribute(
                    .backgroundColor, value: NSColor(EditorTheme.accent).withAlphaComponent(0.18),
                    forCharacterRange: range)
            }
        }
    }

    /// ⌘⇧\: lands the caret on the matching bracket.
    func jumpToMatchingBracket(in textView: NSTextView) {
        let text = textView.string as NSString
        let caret = textView.selectedRange().location
        var anchor: Int?
        if caret > 0, Self.isBracket(codeEditorChar(text, caret - 1)) {
            anchor = caret - 1
        } else if caret < text.length, Self.isBracket(codeEditorChar(text, caret)) {
            anchor = caret
        }
        guard let anchor, let match = bracketMatch(in: text, at: anchor) else { return }
        textView.setSelectedRange(NSRange(location: match, length: 1))
        reveal(NSRange(location: match, length: 1), in: textView)
    }

    static func isBracket(_ character: Character?) -> Bool {
        guard let character else { return false }
        return "([{)]}".contains(character)
    }

    /// The matching bracket for the bracket at `pos`, scanning the full
    /// document with a bracket stack (string literals skipped, escapes
    /// honored). One forward pass - backward string detection is unreliable.
    func bracketMatch(in text: NSString, at pos: Int) -> Int? {
        let openers: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
        let closers: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        var stack: [(open: Character, pos: Int)] = []
        var inString: Character?
        var index = 0
        let length = text.length
        while index < length {
            let character = codeEditorChar(text, index)
            if let quote = inString {
                if character == "\\" {
                    index += 1
                } else if character == quote {
                    inString = nil
                }
            } else if character == "\"" || character == "'" || character == "`" {
                inString = character
            } else if let closer = closers[character ?? " "], let top = stack.last, top.open == closer {
                if index == pos { return top.pos }
                if top.pos == pos { return index }
                stack.removeLast()
            } else if let character, openers[character] != nil {
                stack.append((character, index))
            }
            index += 1
        }
        return nil
    }
}

/// The character at a UTF-16 offset, or nil when out of bounds. Shared by
/// the coordinator's editing extensions.
func codeEditorChar(_ text: NSString, _ offset: Int) -> Character? {
    guard offset >= 0, offset < text.length,
        let scalar = UnicodeScalar(text.character(at: offset))
    else { return nil }
    return Character(scalar)
}

func isWordChar(_ character: Character?) -> Bool {
    guard let character else { return false }
    return character.isLetter || character.isNumber || character == "_"
}

extension EditorCoordinator {
    /// Whether a format handler is installed (the menu's Format item).
    func canFormat(_ textView: NSTextView) -> Bool {
        parent.formatHandler != nil
    }

    /// Whether the current grammar has comments (drives the menu item).
    var supportsComments: Bool {
        parent.syntax.commentStyle != .none
    }
}

// MARK: - Go to line / selection for find / delete to line start

extension EditorCoordinator {
    /// ⌥⌘L's submit: lands the caret on line `line` (1-based, clamped),
    /// optionally at `column` (UTF-16 units into the line's content, the
    /// same ledger the caret stats report; clamped to the line's end) and
    /// scrolls it into view.
    func goToLine(_ line: Int, column: Int? = nil, in textView: NSTextView) {
        let starts = highlighter.lineStartOffsets
        let clamped = min(max(line, 1), max(starts.count, 1))
        // Clamp against the live string: the incremental line ledger could
        // briefly disagree with the storage; an OOB caret here poisons the
        // text system (AppKit throws NSRangeException on the blink rect).
        let length = (textView.string as NSString).length
        var location = min(starts[clamped - 1], length)
        if let column {
            let contentEnd = clamped < starts.count ? starts[clamped] - 1 : length
            let maxColumn = max(contentEnd - location, 0)
            location = min(location + min(max(column, 1) - 1, maxColumn), length)
        }
        textView.setSelectedRange(NSRange(location: location, length: 0))
        reveal(NSRange(location: location, length: 0), in: textView)
    }

    /// ⌥⌘E: the selection becomes the find query (the bar stays closed; the
    /// next ⌘F searches for it).
    func useSelectionForFind(in textView: NSTextView) {
        let selection = textView.selectedRange()
        guard selection.length > 0, selection.length <= 200 else { return }
        let selected = (textView.string as NSString).substring(with: selection)
        guard !selected.contains("\n") else { return }
        parent.findHooks?.useSelection(selected)
    }

    /// ⌘⌫: deletes from the logical line's start to the caret; at the line
    /// start it deletes the preceding newline (joining the line above).
    /// With a selection the platform's delete-selection applies instead.
    /// ⌃K (Monaco `deleteAllRight`): delete from the caret to the line's
    /// content end (the newline stays); with a selection, delete the
    /// whole selection (same as Monaco's behavior for a non-empty
    /// selection).
    func deleteToLineEnd(in textView: NSTextView) {
        guard textView.isEditable, !textView.hasMarkedText() else { return }
        let selection = textView.selectedRange()
        if selection.length > 0 {
            replace(in: textView, range: selection, with: "", caret: selection.location)
            return
        }
        let ns = textView.string as NSString
        let caret = selection.location
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        var end = NSMaxRange(lineRange)
        // Content only: stop before the newline.
        if end > lineRange.location,
            codeEditorChar(ns, end - 1) == "\n"
        {
            end -= 1
        }
        guard end > caret else { return }
        replace(
            in: textView, range: NSRange(location: caret, length: end - caret),
            with: "", caret: caret)
    }

    func deleteToLogicalLineStart(in textView: NSTextView) {
        guard textView.isEditable, textView.selectedRange().length == 0,
            !textView.hasMarkedText()
        else { return }
        let ns = textView.string as NSString
        let caret = textView.selectedRange().location
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        if caret > lineRange.location {
            replace(
                in: textView,
                range: NSRange(location: lineRange.location, length: caret - lineRange.location),
                with: "",
                caret: lineRange.location)
        } else if caret > 0, codeEditorChar(ns, caret - 1) == "\n" {
            replace(
                in: textView,
                range: NSRange(location: caret - 1, length: 1),
                with: "",
                caret: caret - 1)
        }
    }

    // MARK: Definition navigation

    /// F12 / ⌘-click: jumps to the definition of the token under the caret
    /// (Monaco `gotoDefinition`), using the host's `definitionProvider`.
    /// Selection-only: works in read-only editors. No-ops without a
    /// provider or when the provider has nowhere to go.
    func goToDefinition(in textView: NSTextView) {
        guard let provider = parent.definitionProvider,
            !textView.hasMarkedText()
        else { return }
        let selection = textView.selectedRange()
        let length = (textView.string as NSString).length
        let token: NSRange
        if selection.length > 0 {
            let clamped = selection.clampedToString(length)
            token = clamped.length > 0 ? clamped : NSRange(location: min(selection.location, length), length: 0)
        } else {
            let caret = min(max(selection.location, 0), length)
            token =
                caretWordRange(in: textView, caret: caret)
                ?? NSRange(location: caret, length: 0)
        }
        guard token.length > 0,
            let target = provider(token)
        else { return }
        let clamped = target.clampedToString(length)
        guard clamped.length > 0 else { return }
        textView.setSelectedRange(clamped)
        reveal(clamped, in: textView)
    }

    /// ⌘-click variant: jumps the definition of the token at the pointer.
    func goToDefinition(atCharacterIndex index: Int, in textView: NSTextView) {
        guard let provider = parent.definitionProvider,
            !textView.hasMarkedText()
        else { return }
        let length = (textView.string as NSString).length
        let clamped = min(max(index, 0), length)
        let token =
            caretWordRange(in: textView, caret: clamped)
            ?? NSRange(location: clamped, length: 0)
        guard token.length > 0,
            let target = provider(token)
        else { return }
        let targetClamped = target.clampedToString(length)
        guard targetClamped.length > 0 else { return }
        textView.setSelectedRange(targetClamped)
        reveal(targetClamped, in: textView)
    }

    // MARK: Diagnostics navigation

    /// F8 / Shift+F8: jumps to the next/previous diagnostic (Monaco
    /// `gotoNext/PreviousDiagnostic`), wrapping around. Selection-only:
    /// lands on the diagnostic's range and reveals it. No-op without
    /// diagnostics.
    func goToDiagnostic(in textView: NSTextView, up: Bool) {
        let entries = diagnosticEntries.sorted { $0.range.location < $1.range.location }
        guard !entries.isEmpty else { return }
        let caret = textView.selectedRange().location
        if up {
            // Last entry starting before the caret; when the caret sits
            // inside an entry, that entry itself counts as "here".
            let target =
                entries.last(where: { $0.range.location < caret })
                ?? entries.last
            guard let target else { return }
            textView.setSelectedRange(target.range)
            reveal(target.range, in: textView)
        } else {
            let target =
                entries.first(where: { NSMaxRange($0.range) > caret })
                ?? entries.first
            guard let target else { return }
            textView.setSelectedRange(target.range)
            reveal(target.range, in: textView)
        }
    }

    // MARK: Select next/previous match

    /// ⌃⌘D / ⌃⌘⇧D: selects the next/previous occurrence of the word under
    /// the caret (or of the current selection). Single-caret fallback for
    /// Monaco's multi-cursor add-selection: the selection moves instead
    /// of growing. Whole-word matching for word targets, literal
    /// case-insensitive otherwise; wraps like `findLoops`.
    func selectNextMatch(in textView: NSTextView) {
        selectOccurrence(in: textView, forward: true)
    }

    func selectPreviousMatch(in textView: NSTextView) {
        selectOccurrence(in: textView, forward: false)
    }

    private func selectOccurrence(in textView: NSTextView, forward: Bool) {
        let ns = textView.string as NSString
        let selection = textView.selectedRange()
        var target: String?
        var wholeWord = false
        var anchor = selection.location
        var searchStart = NSMaxRange(selection)
        if selection.length > 0 {
            let candidate = ns.substring(with: selection)
            guard !candidate.isEmpty, !candidate.contains("\n") else { return }
            target = candidate
            wholeWord = candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
            anchor = selection.location
            searchStart = NSMaxRange(selection)
        } else {
            let caret = min(max(selection.location, 0), ns.length)
            guard let wordRange = caretWordRange(in: textView, caret: caret),
                wordRange.length > 0
            else { return }
            target = ns.substring(with: wordRange)
            wholeWord = true
            anchor = wordRange.location
            searchStart = NSMaxRange(wordRange)
        }
        guard let target, !target.isEmpty else { return }
        let matches = Self.findMatches(
            in: textView.string, query: target, caseSensitive: false,
            isRegex: false, wholeWord: wholeWord)
        guard !matches.isEmpty else { return }
        // Current slot: the match equal to the selection (or containing
        // the caret word); navigation starts one past it.
        let currentIndex =
            matches.firstIndex(where: { $0 == selection })
            ?? matches.firstIndex(where: { NSLocationInRange(anchor, $0) || $0.location == anchor })
        let next: NSRange?
        if forward {
            if let currentIndex {
                next = matches[(currentIndex + 1) % matches.count]
            } else {
                next =
                    matches.first(where: { $0.location >= searchStart })
                    ?? matches.first
            }
        } else {
            if let currentIndex {
                next = matches[(currentIndex - 1 + matches.count) % matches.count]
            } else {
                next =
                    matches.last(where: { NSMaxRange($0) <= anchor })
                    ?? matches.last
            }
        }
        guard let next else { return }
        textView.setSelectedRange(next)
        reveal(next, in: textView)
    }
}

// MARK: - Word occurrence highlight

extension EditorCoordinator {
    /// Double-click/selection helper: when the selection is a bare word
    /// (letters, digits, underscore, ≤64 chars), washes every occurrence.
    /// Suspended while the find bar owns the background washes.
    /// Scroll `range` into view, then honor `cursorSurroundingLines`:
    /// jump targets keep N of their
    /// lines visible above and below instead of hugging the edge.
    func reveal(_ range: NSRange, in textView: NSTextView) {
        textView.scrollRangeToVisible(range)
        let surrounding = parent.cursorSurroundingLines
        guard surrounding > 0, let layoutManager = textView.layoutManager,
            let container = textView.textContainer,
            let clip = textView.enclosingScrollView?.contentView
        else { return }
        let length = (textView.string as NSString).length
        let glyph = layoutManager.glyphIndexForCharacter(at: min(range.location, length))
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let caretTop = fragment.minY + textView.textContainerOrigin.y
        let lineHeight = max(fragment.height, 1)
        let visible = textView.visibleRect
        let linesAbove = (caretTop - visible.minY) / lineHeight
        let linesBelow = (visible.maxY - caretTop - lineHeight) / lineHeight
        var originY = visible.minY
        if linesAbove < CGFloat(surrounding) {
            originY = caretTop - CGFloat(surrounding) * lineHeight - lineHeight / 4
        } else if linesBelow < CGFloat(surrounding) {
            originY =
                caretTop + lineHeight + CGFloat(surrounding) * lineHeight
                - visible.height + lineHeight / 4
        }
        let documentHeight =
            layoutManager.usedRect(for: container).height
            + textView.textContainerInset.height * 2
        originY = min(max(originY, 0), max(documentHeight - visible.height, 0))
        if abs(originY - visible.minY) > 0.5 {
            clip.setBoundsOrigin(NSPoint(x: visible.minX, y: originY))
        }
    }

    func updateWordHighlight(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        for range in wordHighlightRanges {
            let valid = range.intersection(length)
            guard valid.length > 0 else { continue }
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: valid)
        }
        wordHighlightRanges = []
        guard !parent.find.visible else { return }
        let selection = textView.selectedRange()
        // The wash target: the selected word, or - when the selection is
        // empty and `occurrencesHighlight` is on - the word under the
        // caret (occurrences on the caret word; selection
        // highlight always on).
        var word: String?
        var wholeWord = true
        if selection.length > 0, selection.length <= 64 {
            let candidate = (textView.string as NSString).substring(with: selection)
            if !candidate.isEmpty,
                candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
            {
                word = candidate
            }
        }
        if word == nil, selection.length > 0, parent.selectionHighlight,
            selection.length <= 200
        {
            let candidate = (textView.string as NSString).substring(with: selection)
            if !candidate.isEmpty, !candidate.contains("\n") {
                word = candidate
                wholeWord = false
            }
        }
        if word == nil, selection.length == 0, parent.occurrencesHighlight {
            if let range = caretWordRange(in: textView, caret: min(selection.location, length)),
                range.length <= 64
            {
                word = (textView.string as NSString).substring(with: range)
            }
        }
        guard let word, !word.isEmpty else { return }

        let ns = textView.string as NSString
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: length)
        while searchRange.length > 0 {
            let found = ns.range(of: word, options: [.caseInsensitive], range: searchRange)
            guard found.location != NSNotFound else { break }
            // Whole-word: neither neighbor may be a word character.
            // Plain selection-highlighted text skips the boundary check.
            if !wholeWord {
                ranges.append(found)
            } else {
                let beforeClean =
                    found.location == 0
                    || !isWordChar(codeEditorChar(ns, found.location - 1))
                let afterClean =
                    NSMaxRange(found) >= length
                    || !isWordChar(codeEditorChar(ns, NSMaxRange(found)))
                if beforeClean, afterClean {
                    ranges.append(found)
                }
            }
            searchRange.location = NSMaxRange(found)
            searchRange.length = length - searchRange.location
        }
        wordHighlightRanges = ranges
        let wash = NSColor(EditorTheme.accent).withAlphaComponent(0.12)
        for range in ranges {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: wash, forCharacterRange: range)
        }
    }

    /// The word the caret sits in or immediately follows (either
    /// edge counts). Nil off any word.
    fileprivate func caretWordRange(in textView: NSTextView, caret: Int) -> NSRange? {
        let ns = textView.string as NSString
        let length = ns.length
        func isWord(_ index: Int) -> Bool {
            index >= 0 && index < length && isWordChar(codeEditorChar(ns, index))
        }
        guard caret >= 0, caret <= length else { return nil }
        var start = caret
        var end = caret
        if isWord(caret) {
            end = caret
            while end < length, isWord(end) { end += 1 }
            while start > 0, isWord(start - 1) { start -= 1 }
        } else if isWord(caret - 1) {
            end = caret
            while start > 0, isWord(start - 1) { start -= 1 }
        } else {
            return nil
        }
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}

extension EditorCoordinator {
    /// ⌥⌘L: opens the go-to-line panel (closing the find bar - the two
    /// overlays share the editor's top-right corner).
    func requestLinePanel(in textView: NSTextView) {
        parent.findHooks?.linePanel()
        _ = textView
    }
}

// MARK: Smart select (⌃⇧⌘→ / ⌃⇧⌘←)

extension EditorCoordinator {
    /// Expands the selection one syntactic level out (word → node chain →
    /// line → whole document). Re-seeds automatically after any manual
    /// selection change, so no explicit invalidation is needed.
    func expandSmartSelection(in textView: NSTextView) {
        let current = textView.selectedRange()
        if smartSelectChain.isEmpty
            || smartSelectChain[smartSelectPosition] != current
        {
            smartSelectChain = makeSmartSelectChain(from: current, in: textView)
            smartSelectPosition = 0
        }
        guard smartSelectPosition + 1 < smartSelectChain.count else { return }
        smartSelectPosition += 1
        applySmartSelection(smartSelectChain[smartSelectPosition], in: textView)
    }

    /// Contracts back down the expansion chain (only while the live
    /// selection still matches the chain's head).
    func shrinkSmartSelection(in textView: NSTextView) {
        guard smartSelectPosition > 0,
            smartSelectChain[smartSelectPosition] == textView.selectedRange()
        else { return }
        smartSelectPosition -= 1
        applySmartSelection(smartSelectChain[smartSelectPosition], in: textView)
    }

    private func applySmartSelection(_ range: NSRange, in textView: NSTextView) {
        textView.setSelectedRange(range)
        reveal(range, in: textView)
    }

    /// The expansion chain: the seed selection, then every strictly
    /// containing level (syntax-node ancestry when a tree is retained,
    /// word/line fallbacks otherwise), ending with the whole document.
    private func makeSmartSelectChain(from selection: NSRange, in textView: NSTextView) -> [NSRange] {
        let ns = textView.string as NSString
        let length = ns.length
        var chain: [NSRange] = [selection]
        func push(_ range: NSRange) {
            guard let last = chain.last,
                NSIntersectionRange(range, last).length == last.length,
                range.length > last.length
            else { return }
            chain.append(range)
        }
        if selection.length == 0 {
            let caret = min(selection.location, length)
            if let word = caretWordRange(in: textView, caret: caret) {
                push(word)
            }
        }
        if let ancestry = highlighter.enclosingNodeRanges(
            of: chain.last ?? selection, in: textView.string)
        {
            for range in ancestry.prefix(24) {
                push(range)
            }
        }
        if length > 0 {
            let anchor = min(max(chain.last?.location ?? 0, 0), length - 1)
            var lineRange = ns.lineRange(for: NSRange(location: anchor, length: 0))
            // Content only: the trailing newline is not part of the line.
            if lineRange.length > 0,
                ns.character(at: NSMaxRange(lineRange) - 1)
                    == UInt16(UnicodeScalar("\n").value)
            {
                lineRange.length -= 1
            }
            push(lineRange)
        }
        push(NSRange(location: 0, length: length))
        return chain
    }
}

// MARK: Bracket pair colorization

extension EditorCoordinator {
    /// Paints ()/[]{} by nesting depth as temporary foreground colors.
    /// Strings and comments keep the host's own paint; unmatched closers
    /// stay unpainted. Runs with the diagnostics cadence (after every
    /// edit), tracked ranges removed first like the squiggles.
    func applyBracketColors(in textView: NSTextView) {
        let length = (textView.string as NSString).length
        for range in bracketColorRanges where NSMaxRange(range) <= length && range.length > 0 {
            textView.layoutManager?.removeTemporaryAttribute(
                .foregroundColor, forCharacterRange: range)
        }
        bracketColorRanges = []
        guard parent.bracketPairColorization, length > 0,
            let layoutManager = textView.layoutManager
        else { return }
        let ns = textView.string as NSString
        let hidden = highlighter.stringAndCommentRanges(in: textView.string) ?? []
        let imeMarked = textView.markedRange()
        func hiddenAt(_ index: Int) -> Bool {
            hidden.contains { NSLocationInRange(index, $0) }
        }
        func inMarked(_ index: Int) -> Bool {
            imeMarked.location != NSNotFound && NSLocationInRange(index, imeMarked)
        }
        let palette: [NSColor] = [
            .systemBlue, .systemPurple, .systemTeal,
            .systemOrange, .systemGreen, .systemPink,
        ]
        var depth = 0
        var colored: [(NSRange, NSColor)] = []
        var index = 0
        while index < length {
            let unit = ns.character(at: index)
            let isOpen =
                unit == UInt16(UnicodeScalar("(").value)
                || unit == UInt16(UnicodeScalar("[").value)
                || unit == UInt16(UnicodeScalar("{").value)
            let isClose =
                unit == UInt16(UnicodeScalar(")").value)
                || unit == UInt16(UnicodeScalar("]").value)
                || unit == UInt16(UnicodeScalar("}").value)
            guard isOpen || isClose, !hiddenAt(index), !inMarked(index) else {
                index += 1
                continue
            }
            if isOpen {
                depth += 1
            }
            if depth > 0 {
                let color = palette[(depth - 1) % palette.count].withAlphaComponent(0.9)
                colored.append((NSRange(location: index, length: 1), color))
            }
            if isClose, depth > 0 {
                depth -= 1
            }
            index += 1
        }
        for (range, color) in colored.prefix(2000) {
            layoutManager.addTemporaryAttribute(
                .foregroundColor, value: color, forCharacterRange: range)
            bracketColorRanges.append(range)
        }
    }
}

// MARK: - Syntax diagnostics

extension EditorCoordinator {
    /// After every storage edit and on host-marker updates: dashes the
    /// merged diagnostic ranges (host markers first, then the tree's
    /// ERROR/MISSING ranges) and marks their lines in the gutter. Capped
    /// (20 squiggles, 200 chars each) so one broken brace early in a huge
    /// body doesn't paint half the document.
    func refreshDiagnostics(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        // IME composition: AppKit owns the marked range's styling — squiggles
        // on it would fight the composition underline (and read as noise).
        let imeMarkedRange: NSRange = textView.markedRange()
        func intersectsMarked(_ range: NSRange) -> Bool {
            imeMarkedRange.location != NSNotFound
                && NSIntersectionRange(range, imeMarkedRange).length > 0
        }
        for range in diagnosticUnderlineRanges {
            // IME replacement (and any shrinking edit) leaves the previous
            // squiggle ranges past the live length; removeTemporaryAttribute
            // throws on out-of-bounds ranges - clamp, never crash in a
            // delegate running inside text processing.
            var valid = range
            if NSMaxRange(valid) > length {
                valid = NSRange(location: valid.location, length: max(0, length - valid.location))
            }
            guard valid.length > 0 else { continue }
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: valid)
            layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: valid)
        }
        diagnosticUnderlineRanges = []
        diagnosticEntries = []

        // Host markers first (a dry-run error outranks transient parse
        // noise), then the parse's own diagnostics; severity carries the
        // paint color for squiggle, gutter dot, and tooltip.
        var entries: [DiagnosticEntry] = hostMarkers.map {
            DiagnosticEntry(range: $0.range, message: $0.message, severity: $0.severity)
        }
        for (range, message) in highlighter.diagnostics() {
            entries.append(DiagnosticEntry(range: range, message: message, severity: .error))
        }

        let style = NSNumber(value: NSUnderlineStyle.patternDash.rawValue)
        // Squiggles only when the
        // mode says so (.editable tracks the editor's editability); gutter
        // dots and tooltips always reflect the real diagnostics.
        let showDecorations: Bool
        switch parent.renderValidationDecorations {
        case .off: showDecorations = false
        case .editable: showDecorations = textView.isEditable
        case .on: showDecorations = true
        }
        var lineSeverities: [Int: EditorMarkerSeverity] = [:]
        var underlineRanges: [NSRange] = []
        for entry in entries where underlineRanges.count < 20 {
            var squiggle = entry.range.clampedToString(length)
            guard squiggle.length > 0 else { continue }
            if squiggle.length > 200 { squiggle.length = 200 }
            underlineRanges.append(squiggle)
            let line = highlighter.lineNumber(ofUTF16Offset: squiggle.location)
            if let existing = lineSeverities[line] {
                // One dot per line; the most severe marker wins.
                lineSeverities[line] = max(existing, entry.severity)
            } else {
                lineSeverities[line] = entry.severity
            }
            guard showDecorations, !intersectsMarked(squiggle) else { continue }
            layoutManager.addTemporaryAttribute(.underlineStyle, value: style, forCharacterRange: squiggle)
            layoutManager.addTemporaryAttribute(
                .underlineColor, value: entry.severity.nsColor, forCharacterRange: squiggle)
        }
        diagnosticUnderlineRanges = underlineRanges
        diagnosticEntries = underlineRanges.enumerated().map { index, range in
            DiagnosticEntry(range: range, message: entries[index].message, severity: entries[index].severity)
        }
        if let gutter = rootView?.gutterView {
            gutter.lineSeverities = lineSeverities
            gutter.needsDisplay = true
        }
        rootView?.rulerView?.needsDisplay = true
        // Clickable links re-scan with the same cadence as the squiggles:
        // after every edit, over the fresh layout.
        applyLinks(in: textView)
        // Bracket pairs re-color with the same cadence.
        applyBracketColors(in: textView)
    }
}

extension NSRange {
    /// Clipped against `length` (stale ranges from a smaller previous
    /// document must never reach NSLayoutManager - it throws on OOB).
    fileprivate func intersection(_ length: Int) -> NSRange {
        let start = min(max(location, 0), length)
        let end = min(max(NSMaxRange(self), start), length)
        return NSRange(location: start, length: end - start)
    }
}

extension NSRange {
    /// Clamped to `0...length`, empty ranges dropped.
    fileprivate func clampedToString(_ length: Int) -> NSRange {
        guard location != NSNotFound else { return NSRange(location: 0, length: 0) }
        let start = min(max(location, 0), length)
        let end = min(max(location + self.length, start), length)
        return NSRange(location: start, length: end - start)
    }
}

// MARK: - Paste and format

extension EditorCoordinator {
    /// Attempts one paste of `pasted` through the format handler.
    /// Returns true when the formatted insert was consumed (the caller
    /// must not fall back to a plain paste); false means the handler is
    /// missing or the text does not parse and the caller should paste
    /// plainly. The insert itself suppresses `formatOnType` rescheduling.
    func formatPastedString(_ pasted: String, in textView: NSTextView) -> Bool {
        guard textView.isEditable, !textView.hasMarkedText(),
            let formatHandler = parent.formatHandler, !pasted.isEmpty
        else { return false }
        let formatted: String
        do {
            formatted = try formatHandler(pasted) ?? pasted
        } catch {
            return false
        }
        let range = textView.selectedRange()
        guard textView.shouldChangeText(in: range, replacementString: formatted) else { return true }
        isFormatting = true
        textView.textStorage?.replaceCharacters(in: range, with: formatted)
        textView.didChangeText()
        isFormatting = false
        textView.setSelectedRange(NSRange(location: range.location + (formatted as NSString).length, length: 0))
        return true
    }

    /// ⌥⇧⌘V / context menu: pastes the pasteboard string through the
    /// format handler (minified JSON lands pretty-printed). Falls back to
    /// a plain paste when there is no handler, the pasteboard is empty,
    /// or the text does not parse.
    func pasteAndFormat(in textView: NSTextView) {
        guard let pasted = NSPasteboard.general.string(forType: .string), !pasted.isEmpty,
            textView.isEditable
        else {
            textView.pasteAsPlainText(nil)
            return
        }
        if formatPastedString(pasted, in: textView) { return }
        textView.pasteAsPlainText(nil)
    }
}
