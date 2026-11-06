import AppKit
import SwiftUI

/// The overview ruler (Monaco: `overviewRulerLanes`): a narrow strip right
/// of the text showing the whole document's markers at proportional
/// heights - diagnostics in their severity color, find matches in the
/// warning color, the caret line in the accent color - plus a subtle band
/// for the visible viewport. Doubles as the scroll affordance the editor
/// otherwise hides: click/drag scrolls proportionally.
///
/// Marks are content-anchored (offset/documentLength), so the view only
/// redraws on edits, diagnostics, find, and layout changes - not per
/// scroll tick.
final class EditorOverviewRulerView: NSView {
    static let width: CGFloat = 14
    weak var textView: NSTextView?
    weak var coordinator: EditorCoordinator?

    private var scrollObserver: NSObjectProtocol?

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

    isolated deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    /// Left hairline separating the ruler from the text (Monaco:
    /// `overviewRulerBorder`).
    var showsBorder = true
    /// Hide the caret tick (Monaco: `hideCursorInOverviewRuler`).
    var hidesCursor = false

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let safe = dirtyRect.intersection(bounds)
        guard !safe.isNull, safe.width > 0, safe.height > 0 else { return }
        EditorTheme.codeBackgroundNS.setFill()
        safe.fill()
        // Left hairline separating the ruler from the text.
        if showsBorder {
            NSColor(EditorTheme.border).setFill()
            NSRect(x: bounds.minX, y: bounds.minY, width: 1, height: bounds.height).fill()
        }

        guard let textView, let coordinator, bounds.height > 1 else { return }
        let length = max((textView.string as NSString).length, 1)
        let track = NSRect(x: bounds.minX + 3, y: bounds.minY + 1, width: bounds.width - 5, height: bounds.height - 2)

        // Content-anchored y: offset/length maps linearly onto the track
        // (monospace lines are uniform enough for 2px ticks).
        func yFraction(_ offset: Int) -> CGFloat {
            track.minY + CGFloat(min(max(offset, 0), length)) / CGFloat(length) * track.height
        }

        // Viewport band first (under everything): where the user is.
        if let clipView = textView.enclosingScrollView?.contentView {
            let documentHeight = max(
                textView.layoutManager?.usedRect(for: textView.textContainer ?? NSTextContainer()).height
                    ?? textView.bounds.height,
                clipView.bounds.height)
            if documentHeight > 0 {
                let top = min(max(clipView.bounds.minY / documentHeight, 0), 1)
                let bottom = min(max((clipView.bounds.minY + clipView.bounds.height) / documentHeight, 0), 1)
                let bandTop = track.minY + top * track.height
                let bandHeight = (bottom - top) * track.height
                EditorTheme.textPrimaryNS.withAlphaComponent(0.06).setFill()
                NSRect(x: track.minX, y: bandTop, width: track.width, height: max(bandHeight, 2)).fill()
            }
        }

        // Find matches: warning ticks (under diagnostics).
        let findColor = NSColor(EditorTheme.warning).withAlphaComponent(0.75)
        findColor.setFill()
        for range in coordinator.findMatches {
            NSRect(x: track.minX, y: yFraction(range.location) - 1, width: track.width * 0.6, height: 2).fill()
        }

        // Diagnostics: severity ticks, drawn over find matches.
        for entry in coordinator.diagnosticEntries {
            entry.severity.nsColor.setFill()
            NSRect(x: track.minX + track.width * 0.2, y: yFraction(entry.range.location) - 1, width: track.width * 0.8, height: 2).fill()
        }

        // Caret line: accent tick.
        if !hidesCursor {
            let caret = min(textView.selectedRange().location, length)
            NSColor(EditorTheme.accent).setFill()
            NSRect(x: track.minX, y: yFraction(caret) - 0.5, width: track.width, height: 1).fill()
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
    /// proportional position (Monaco's ruler drags the same way).
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
