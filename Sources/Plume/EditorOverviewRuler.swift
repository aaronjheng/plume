import AppKit
import SwiftUI

/// The overview ruler: a narrow strip right of the text. The caret-line
/// band continues into it at its on-screen row - mirrored live from the
/// text view so it reads as one row across the strip's hairline. The
/// strip also doubles as the scroll affordance the editor otherwise
/// hides: a viewport-proportional slider; click/drag scrolls
/// proportionally. On top of both sits the caret tick (Monaco's
/// `hideCursorInOverviewRuler`): a short bar at the caret line's top on
/// the same row the band continues into, so it reads as one marker.

///
/// Redraws on scroll ticks, and via its own observers on the text view
/// on selection changes and edits.
final class EditorOverviewRulerView: NSView {
    static let width: CGFloat = 14
    weak var textView: NSTextView? {
        didSet { installObservers() }
    }
    weak var coordinator: EditorCoordinator?

    private var scrollObserver: NSObjectProtocol?
    private var selectionObserver: NSObjectProtocol?
    private var editObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }

    /// The viewport band moves with the clip view, so the ruler redraws on
    /// every scroll tick (same pattern as the gutter).
    func observeScroll(of scrollView: NSScrollView) {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.needsDisplay = true
            }
        }
    }

    /// The strip mirrors the text view's selection wash and caret band,
    /// so it repaints from the text view's own notifications instead of
    /// relying on the coordinator's invalidation paths - every selection
    /// change and edit repaints the strip even if a wiring path misses.
    private func installObservers() {
        guard let textView, selectionObserver == nil else { return }
        let center = NotificationCenter.default
        selectionObserver = center.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: textView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.needsDisplay = true
            }
        }
        editObserver = center.addObserver(
            forName: NSText.didChangeNotification, object: textView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.needsDisplay = true
            }
        }
    }

    isolated deinit {
        for observer in [scrollObserver, selectionObserver, editObserver] {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    /// Left hairline separating the ruler from the text.
    var showsBorder = true
    /// Hide the caret tick.
    var hidesCursor = false

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let safe = dirtyRect.intersection(bounds)
        guard !safe.isNull, safe.width > 0, safe.height > 0 else { return }
        // Opaque code-background base: the strip sits over the text view's
        // right edge, and anything the text view draws there (selection
        // wash spilling past the container) must not show through. The
        // ruler elements (hairline, ticks, slider) draw on top of it.
        EditorTheme.codeBackgroundNS.setFill()
        safe.fill()
        // Left hairline separating the ruler from the text (Monaco:
        // editorOverviewRuler.border, 30% gray).
        if showsBorder {
            EditorTheme.overviewRulerBorderNS.setFill()
            NSRect(x: bounds.minX, y: bounds.minY, width: 1, height: bounds.height).fill()
        }

        guard let textView, let coordinator, bounds.height > 1,
            textView.window === window
        else { return }

        // The caret-line band CONTINUES into the strip at its on-screen
        // row: the band rect is converted straight from the text view's
        // coordinates, so it reads as one row across the hairline and
        // tracks scrolling live (scrolled out of the viewport it clips
        // away). The selection itself is not mirrored: it hugs the
        // characters (see `drawSelectionWash`), so there is no full-width
        // row to continue. The slider below is backed by an opaque
        // code-background fill, so it stays untinted.
        //
        // The row is clipped to `bounds` by hand: scrolled out of the
        // viewport the converted rect runs negative (or past the strip's
        // height), and AppKit does not clip NSView drawing to bounds under
        // the hosted hierarchy - the fill and its two border lines painted
        // over the chrome around the editor (the tab bar, the Send row).
        func fillClipped(_ rect: NSRect) {
            let visible = rect.intersection(bounds)
            guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }
            visible.fill()
        }
        if coordinator.parent.renderLineHighlight == .line
            || coordinator.parent.renderLineHighlight == .all
        {
            let bandVisible =
                !coordinator.parent.renderLineHighlightOnlyWhenFocus
                || textView.window?.firstResponder === textView
            if bandVisible, let editorText = textView as? EditorTextView,
                !editorText.lineBandRect.isEmpty
            {
                let band = convert(editorText.lineBandRect, from: textView)
                EditorTheme.lineHighlightBackgroundNS.setFill()
                fillClipped(
                    NSRect(x: bounds.minX, y: band.minY, width: bounds.width, height: band.height))
                let borderWidth = EditorTheme.lineHighlightBorderWidth
                if borderWidth > 0 {
                    EditorTheme.lineHighlightBorderNS.setFill()
                    fillClipped(
                        NSRect(
                            x: bounds.minX, y: band.minY, width: bounds.width,
                            height: borderWidth))
                    fillClipped(
                        NSRect(
                            x: bounds.minX, y: band.maxY - borderWidth,
                            width: bounds.width, height: borderWidth))
                }
            }
        }

        // Caret tick (Monaco `decorationsOverviewRuler`'s "Draw cursors"):
        // one short bar per caret, anchored at the caret line's TOP IN
        // SCREEN ROWS - the strip mirrors the band at its on-screen row (see
        // above), so the tick rides along with that row and with scrolling,
        // clipping away once the caret's line leaves the viewport. Caret
        // color at 70% (Monaco tints `editorCursor.foreground` with 0.7),
        // and off entirely under `hideCursorInOverviewRuler`. Height is
        // Monaco's `2 * pixelRatio`.
        if !hidesCursor, let layoutManager = textView.layoutManager,
            let container = textView.textContainer
        {
            let nsString = textView.string as NSString
            let caret = min(textView.selectedRange().location, nsString.length)
            func caretLineTop() -> CGFloat? {
                if caret == nsString.length, layoutManager.extraLineFragmentTextContainer != nil {
                    return layoutManager.extraLineFragmentRect.minY
                }
                let lineRange = nsString.lineRange(for: NSRange(location: caret, length: 0))
                let glyphs = layoutManager.glyphRange(
                    forCharacterRange: lineRange, actualCharacterRange: nil)
                guard glyphs.length > 0 else { return nil }
                return layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                    .minY
            }
            if let lineTop = caretLineTop() {
                // Text view -> strip: the fragment rects start at the container
                // origin (the inset the band carries too), and the conversion
                // through the enclosing scroll view picks up the scroll offset
                // the same way the band mirror does.
                let top = convert(
                    NSPoint(x: 0, y: lineTop + textView.textContainerOrigin.y), from: textView
                ).y
                // No edge clamp here (unlike Monaco's document-mapped tick):
                // the row simply leaves the strip with the caret, and
                // `fillClipped` drops it while it is off-screen.
                let tickHeight: CGFloat = 2
                coordinator.insertionColorNS.withAlphaComponent(0.7).setFill()
                fillClipped(
                    NSRect(
                        x: bounds.minX, y: top - tickHeight / 2, width: bounds.width,
                        height: tickHeight))
            }
        }

        // Slider thumb LAST (Monaco draws the scrollbar over the ruler
        // canvas): full strip width, viewport-proportional height, min
        // 20pt (Monaco's MINIMUM_SLIDER_SIZE), and nothing at all when
        // the content fits the viewport (Monaco skips the slider then).
        if let clipView = textView.enclosingScrollView?.contentView {
            let contentHeight =
                textView.layoutManager?.usedRect(
                    for: textView.textContainer ?? NSTextContainer()
                ).height
                ?? textView.bounds.height
            let viewportHeight = clipView.bounds.height
            if contentHeight > viewportHeight {
                let documentHeight = max(contentHeight, viewportHeight)
                let top = min(max(clipView.bounds.minY / documentHeight, 0), 1)
                let bottom = min(
                    max((clipView.bounds.minY + viewportHeight) / documentHeight, 0), 1)
                let thumbTop = top * bounds.height
                let thumbHeight = max((bottom - top) * bounds.height, 20)
                // Opaque backing under the translucent slider: the wash
                // continues behind the strip, and without this the slider
                // would pick it up and read tinted.
                EditorTheme.codeBackgroundNS.setFill()
                NSRect(
                    x: bounds.minX, y: thumbTop,
                    width: bounds.width, height: min(thumbHeight, bounds.height - thumbTop)
                ).fill()
                EditorTheme.scrollbarSliderNS.setFill()
                NSRect(
                    x: bounds.minX, y: thumbTop,
                    width: bounds.width, height: min(thumbHeight, bounds.height - thumbTop)
                ).fill()
            }
        }
    }

    // MARK: - Proportional scrolling

    override func mouseDown(with event: NSEvent) {
        scroll(to: convert(event.locationInWindow, from: nil).y)
    }

    override func mouseDragged(with event: NSEvent) {
        scroll(to: convert(event.locationInWindow, from: nil).y)
    }

    /// Puts the document point at `pointerY` under the pointer's
    /// proportional position.
    private func scroll(to pointerY: CGFloat) {
        guard let textView, let scrollView = textView.enclosingScrollView,
            bounds.height > 0
        else { return }
        let ns = textView.string as NSString
        guard ns.length > 0 else { return }
        let documentHeight =
            textView.layoutManager?.usedRect(for: textView.textContainer ?? NSTextContainer()).height
            ?? textView.bounds.height
        let viewportHeight = scrollView.contentView.bounds.height
        guard documentHeight > viewportHeight else { return }
        let fraction = min(max(pointerY / bounds.height, 0), 1)
        let targetY = fraction * (documentHeight - viewportHeight)
        let target = NSPoint(x: scrollView.contentView.bounds.minX, y: targetY)
        scrollView.contentView.scroll(to: target)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
