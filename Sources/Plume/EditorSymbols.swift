import AppKit
import SwiftUI

/// The kind of a `EditorDocumentSymbol`, shown as a small label in the
/// outline list (Monaco's symbol kind).
public enum EditorDocumentSymbolKind: Equatable, Sendable {
    case `function`
    case `class`
    case `variable`
    case `method`
    case `constant`
    case `key`

    /// Short label shown beside the name in the outline.
    public var label: String {
        switch self {
        case .function: "function"
        case .class: "class"
        case .variable: "variable"
        case .method: "method"
        case .constant: "constant"
        case .key: "key"
        }
    }
}

/// One entry in the document outline (Monaco's `DocumentSymbol`): a
/// named construct and the range jumping to it selects.
public struct EditorDocumentSymbol: Identifiable, Equatable, Sendable {
    public let name: String
    /// UTF-16 range of the symbol name in the document.
    public let range: NSRange
    public let kind: EditorDocumentSymbolKind

    public init(name: String, range: NSRange, kind: EditorDocumentSymbolKind) {
        self.name = name
        self.range = range
        self.kind = kind
    }

    public var id: String { "\(range.location)-\(range.length)-\(name)" }
}

/// Case-insensitive substring outline filter (Monaco's symbol search):
/// prefix matches first, then substring, keeping document order.
public enum DocumentSymbolFilter {
    public static func filtered(_ symbols: [EditorDocumentSymbol], by query: String) -> [EditorDocumentSymbol] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return symbols }
        let needle = trimmedQuery.lowercased()
        let prefix = symbols.filter { $0.name.lowercased().hasPrefix(needle) }
        let rest = symbols.filter {
            !$0.name.lowercased().hasPrefix(needle) && $0.name.lowercased().contains(needle)
        }
        return prefix + rest
    }
}

/// The document-outline card: a filter field and symbol list (Monaco's
/// `Ctrl+Shift+O` panel). Pure presentation.
public struct EditorDocumentSymbolsBar: View {
    @Binding var query: String
    let symbols: [EditorDocumentSymbol]
    @Binding var selectedIndex: Int
    let onClose: () -> Void
    let onPick: (EditorDocumentSymbol) -> Void

    @FocusState private var focused: Bool

    static let rowHeight: CGFloat = 26
    static let maxVisibleRows = 8
    static let panelWidth: CGFloat = 320

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Filter symbols", text: $query)
                .font(EditorTheme.fontMonoSubheadline)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .focused($focused)
                .padding(.horizontal, EditorTheme.spaceCompact)
                .frame(width: Self.panelWidth, height: 26)
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
                .help("Outline — filter by name")
            if symbols.isEmpty {
                Text("No symbols")
                    .font(EditorTheme.fontSmall)
                    .foregroundStyle(EditorTheme.tertiaryText)
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(symbols.enumerated()), id: \.element.id) { index, symbol in
                                row(index, symbol)
                                    .id(symbol.id)
                            }
                        }
                    }
                    .frame(width: Self.panelWidth, height: CGFloat(min(symbols.count, Self.maxVisibleRows)) * Self.rowHeight)
                    .onChange(of: selectedIndex) { _, newIndex in
                        guard symbols.indices.contains(newIndex) else { return }
                        proxy.scrollTo(symbols[newIndex].id)
                    }
                }
            }
            Text("↑↓ Navigate   ↩ Jump   esc Dismiss")
                .font(EditorTheme.fontSmall)
                .foregroundStyle(EditorTheme.tertiaryText)
                .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
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
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onKeyPress(.upArrow) {
            if !symbols.isEmpty {
                selectedIndex = (selectedIndex - 1 + symbols.count) % symbols.count
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if !symbols.isEmpty {
                selectedIndex = (selectedIndex + 1) % symbols.count
            }
            return .handled
        }
        .onKeyPress(.return) {
            if symbols.indices.contains(selectedIndex) {
                onPick(symbols[selectedIndex])
            }
            return .handled
        }
        .onExitCommand { onClose() }
    }

    private func row(_ index: Int, _ symbol: EditorDocumentSymbol) -> some View {
        HStack(spacing: EditorTheme.spaceXSmall) {
            Text(symbol.kind.label)
                .font(EditorTheme.fontSmall)
                .foregroundStyle(EditorTheme.tertiaryText)
                .frame(width: 64, alignment: .leading)
            Text(symbol.name)
                .font(EditorTheme.fontMonoSubheadline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: EditorTheme.spaceSmall)
        }
        .padding(.horizontal, EditorTheme.spaceSmall)
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .leading)
        .background(index == selectedIndex ? EditorTheme.tabActiveBackground : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { selectedIndex = index }
        }
        .onTapGesture { onPick(symbol) }
        .pointerStyle(.link)
    }

    static func cardSize() -> CGSize {
        CGSize(width: 320 + 2 * EditorTheme.spaceSmall, height: 26 + 6 + 8 * rowHeight + 20 + 6 + 2 * EditorTheme.spaceSmall)
    }
}
