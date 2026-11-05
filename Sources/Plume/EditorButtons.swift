import AppKit
import SwiftUI

// MARK: - Cursor claim

/// The AppKit-level cursor claim for editor-overlay buttons. SwiftUI's
/// `.pointerStyle` loses to AppKit cursor sources underneath the overlay:
/// the text view's tracking areas are not occluded by SwiftUI layer
/// content, so they keep re-stamping their cursor no matter what the
/// overlay's styles set. The claim is a REAL view at the button's frame -
/// frontmost in the window's view tree - that declares the cursor through
/// the window's own machinery (cursor rects, plus a tracking area with a
/// `cursorUpdate` handler), so every resolution path lands on it first.
/// `hitTest` returns nil: the claim never takes clicks; the SwiftUI button
/// it sits behind keeps them.
struct CursorClaim: NSViewRepresentable {
    var cursor: NSCursor

    func makeNSView(context: Context) -> ClaimView {
        ClaimView(cursor: cursor)
    }

    func updateNSView(_ view: ClaimView, context: Context) {
        view.claimedCursor = cursor
    }

    final class ClaimView: NSView {
        var claimedCursor: NSCursor {
            didSet {
                guard claimedCursor != oldValue else { return }
                window?.invalidateCursorRects(for: self)
            }
        }

        init(cursor: NSCursor) {
            self.claimedCursor = cursor
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("created in code only") }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: claimedCursor)
        }

        override func cursorUpdate(with event: NSEvent) {
            claimedCursor.set()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                    owner: self))
        }
    }
}

/// Editor-owned button chrome for the find/replace and go-to-line overlays.
/// Mirrors the host's button styles with the same hover language, but reads
/// only `EditorTheme` - the overlays must extract with the editor package
/// without dragging the host's whole button family along. Keep the two
/// families visually in step; divergence here reads as inconsistency
/// inside the editor overlays.
struct EditorSecondaryButtonStyle: ButtonStyle {
    var isDestructive = false
    var isAccented = false
    var minHeight: CGFloat?
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .foregroundStyle(
                isEnabled
                    ? (isDestructive
                        ? EditorTheme.error
                        : (isAccented ? EditorTheme.accent : EditorTheme.textPrimary))
                    : EditorTheme.textSecondary
            )
            .padding(.horizontal, EditorTheme.spaceMedium)
            .padding(.vertical, EditorTheme.spaceXSmall)
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: EditorTheme.radiusMedium, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? EditorTheme.border
                            : (isEnabled && isHovering ? EditorTheme.subtleBackground : EditorTheme.fieldBackground)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: EditorTheme.radiusMedium, style: .continuous)
                    .strokeBorder(
                        isDestructive ? EditorTheme.destructiveBorder : EditorTheme.borderStrong,
                        lineWidth: EditorTheme.lineField
                    )
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : EditorTheme.opacityDisabled)
            .onHover { isHovering = $0 }
            .pointerStyle(isEnabled ? .link : .default)
            // The AppKit-level claim (see CursorClaim): pointerStyle alone
            // loses to the editor's cursor sources underneath the overlay.
            .background(CursorClaim(cursor: isEnabled ? .pointingHand : .arrow))
            .animation(EditorTheme.motionQuick, value: configuration.isPressed)
            .animation(EditorTheme.motionQuick, value: isHovering)
    }
}

/// The editor overlay's icon button - the find bar's option toggles
/// (`Aa`/`ab`/`.*`, `AB`), its previous/next arrows, the replace toggle and
/// the close: the icon-chrome hover language plus the pointing hand while
/// enabled, `.default` while disabled.
///
/// The pointer style has to live HERE, inside `makeBody`, the way the hosts'
/// own icon-button styles do it. On the `Button` itself - or on a label
/// under `.buttonStyle(.plain)` - it never takes effect, and the cursor then
/// falls through to the `NSTextView` underneath the overlay, whose I-beam
/// covers the whole editor including this bar.
struct EditorIconButtonStyle: ButtonStyle {
    var isActive = false
    var size: CGFloat = 20
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isActive ? EditorTheme.accent : EditorTheme.textSecondary)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: EditorTheme.radiusSmall, style: .continuous)
                    .fill(
                        isActive
                            ? EditorTheme.subtleBackground
                            : (isEnabled && isHovering ? EditorTheme.tabHoverBackground : .clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: EditorTheme.radiusSmall, style: .continuous)
                    .strokeBorder(isActive ? EditorTheme.border : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : EditorTheme.opacityDisabled)
            .onHover { isHovering = $0 }
            .pointerStyle(isEnabled ? .link : .default)
            // The AppKit-level claim (see CursorClaim): pointerStyle alone
            // loses to the editor's cursor sources underneath the overlay.
            .background(CursorClaim(cursor: isEnabled ? .pointingHand : .arrow))
    }
}
