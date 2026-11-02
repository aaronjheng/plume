# Plume

A macOS code editor base library for SwiftUI apps: a standalone `NSTextView`
pipeline with incremental tree-sitter highlighting, a line-number gutter with
error diagnostics, find/replace, go-to-line, and line operations - built once,
consumed by Canoe (API client) and Runlet (Redis client).

## What's inside

- **Incremental highlighting**: one retained parse tree per editor; every
  keystroke repaints only the edited lines plus the parse's changed ranges.
- **Syntax profiles**: `SyntaxProfile` pairs a tree-sitter grammar with its
  paint walk. The package ships no grammars - hosts define every language
  (json, xml, javascript, bash, lua, ...) on their side.
- **Injected host integration**: chrome tokens (`EditorTheme`, set at app
  launch), annotation washes, an opaque completion engine, and a formatting
  handler - a host without any of them simply passes nothing.
- **Editing assists**: enter-line indent carry, Tab/Shift-Tab block indent,
  bracket/quote auto-pairing with skip-over, per-profile comment toggling,
  duplicate/delete/move line, read-only selectable mode, placeholders,
  auto-grow and fill-container sizing.
- **Language-service hooks** (the Monaco set that makes sense embedded):
  completions (`suggestFactory` + `triggerCharacters`), hovers
  (`hoverProvider`), formatting (`formatHandler`), tokens (`SyntaxHighlight`).

## Usage

```swift
import Plume

// At app launch: install your chrome (see the token table below).
EditorTheme.accent = .accentColor
EditorTheme.spaceMedium = 12
// ...

// Define a syntax profile over your grammar (package ships none).
extension SyntaxProfile {
    static let bash = SyntaxProfile(
        id: "bash",
        language: { tree_sitter_bash().map { Language($0) } },
        paint: { root, length, cursor, runs in
            myPaintWalk(root, length, &cursor, &runs)   // EditorTheme colors
        },
        commentStyle: .line(prefix: "# "))
}

// In a view:
Editor(
    text: $text,
    annotations: { source in tintedRanges(in: source) },  // optional washes
    syntax: .bash,
    suggestFactory: { SuggestBridge() },                  // optional
    placeholder: "Enter a query…")
```

### Composing a suggest engine

The suggest subsystem is host-bridged: implement `EditorSuggestControlling`
by forwarding onto a `SuggestController` you own.

```swift
@MainActor
final class MySuggestBridge: EditorSuggestControlling {
    private let engine = SuggestController(triggerCharacters: ["."])

    func candidatesChanged(_ candidates: [Any]) {
        engine.setCandidates(candidates as? [SuggestItem] ?? [])
    }
    func textChanged(_ textView: NSTextView) {
        // Refilter the universe for the caret, then hand it over.
        engine.setWordCandidates(universe(for: textView))
        engine.textChanged(textView)   // "." auto-opens via triggerCharacters
    }
    func selectionChanged(_ textView: NSTextView) { engine.selectionChanged(textView) }
    func handleCommand(_ selector: Selector) -> Bool { engine.handleCommand(selector) }
    var isVisible: Bool { engine.isVisible }
    func hide() { engine.hide() }
}
```

### EditorTheme token table

Every chrome token the editor reads; assign once at launch. Missing tokens
fall back to neutral system defaults.

| Slot | Tokens |
|---|---|
| Semantic | `accent` `success` `error` `warning` |
| Text | `textPrimary` `textSecondary` `tertiaryText` |
| Lines & borders | `border` `borderStrong` `destructiveBorder` |
| Surfaces | `controlBackground` `fieldBackground` `subtleBackground` |
| Tab chrome | `tabHoverBackground` `tabActiveBackground` |
| Overlay | `popupShadow` |
| AppKit fills | `textPrimaryNS` `codeBackgroundNS` |
| Syntax roles | `syntaxKey` `syntaxString` `syntaxNumber` `syntaxKeyword` `syntaxPlain` |
| Fonts (SwiftUI) | `fontSmall` `fontMonoSubheadline` `fontMonoBody` `fontMonoURLBar` `fontMonoCaption` `fontIconCompact` |
| Metrics | `spaceXSmall` `spaceSmall` `spaceCompact` `spaceMedium` |
| Radii | `radiusSmall` `radiusMedium` |
| Line widths | `lineField` `lineFocusedField` |
| Misc | `toggleControlSize` `opacityDisabled` `motionQuick` |

Colors stay dynamic (light/dark adaptive) after the one-time install.

## Non-goals

Minimap, code folding, multi-cursor, and a full decoration API are deliberate
non-goals - Plume targets lightweight embedding, not IDE parity.

## Build

```bash
just build    # swift build -c release
just lint     # swiftlint
just format   # swift-format
```

Swift 6 tools, macOS 26+, no tests by policy (see the host apps' repos).

## License

Plume is licensed under the [BSD-3-Clause License](https://opensource.org/licenses/BSD-3-Clause). See [LICENSE](LICENSE) for more details.
