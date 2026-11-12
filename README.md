# Plume

A macOS code editor base library for SwiftUI apps: a standalone `NSTextView`
pipeline with incremental tree-sitter highlighting, a line-number gutter with
severity-graded diagnostics, regex find/replace, go-to-line/`line:column`,
line operations and transforms, an overview ruler, and configurable
indentation/wrapping - built once, consumed by Canoe (API client) and Runlet
(Redis client).

## What's inside

- **Incremental highlighting**: one retained parse tree per editor; every
  keystroke repaints only the edited lines plus the parse's changed ranges.
- **Syntax profiles**: `SyntaxProfile` pairs a tree-sitter grammar with its
  paint walk. The core package ships none; the `PlumeLanguages` product
  layers preset profiles for the common embedded languages (json, xml,
  html, javascript, bash, lua) on top, and hosts define further languages on
  their side.
- **Injected host integration**: chrome tokens (`EditorTheme`, set at app
  launch), annotation washes, an opaque completion engine, and a formatting
  handler - a host without any of them simply passes nothing.
- **Editing assists**: enter-line indent carry, Tab/Shift-Tab and ⌘]/⌘[
  block indent, per-language bracket/quote auto-pairing (`SyntaxProfile`
  brackets + `autoClosing`/`autoSurround`; Backspace deletes a matched
  empty pair) with skip-over, per-profile comment toggling (⌘/) and
  block-comment toggling (⇧⌥A), duplicate/delete/copy/move line,
  upper/lowercase, sort
  lines, join lines, trim trailing whitespace, read-only selectable mode,
  placeholders, auto-grow and fill-container sizing.
- **Diagnostics**: host-injected
  `EditorMarker`s (severity/range/message) render as squiggles, gutter
  dots, and tooltips alongside the parse's own syntax errors; the
  overview ruler (`showsOverviewRuler`) plots them as ticks with a
  viewport band and doubles as click/drag-to-scroll.
- **Find/replace**: match case, whole word (`ab`),
  regular expressions (`.*`, `$1` templates in replacements), preserve
  case (`AB`), match count/index, replace and replace-all, Up/Down
  query history, invalid-regex hint, and a retained last search so
  ⌘G/⌘⇧G still navigate after the bar is dismissed.
- **Indentation & wrapping**: `tabSize`/`insertSpaces`/
  `detectIndentation` (indent guides track literal tabs too), `wordWrap`
  (`.on`/`.off`/`.column(n)`), and go-to-line accepting `line:column`.
- **Navigation**: F8/Shift+F8 diagnostic jumps, ⌃⌘D/⌃⌘⇧D word-occurrence
  selection (⌘D keeps duplicate-lines), editor-local zoom
  (⌃= / ⌃- / ⌃0, starting from `initialFontScale`), toggle wrap (⌥Z),
  transpose (⌃T), and auto-outdent for typing `}`/`]`/`)`/`>`.
- **Rendering options**: `rulers`, `renderLineHighlight`
  (`.none`/`.gutter`/`.line`/`.all` + only-when-focus), `renderWhitespace`
  (`.none`/`.trailing`/`.boundary`/`.selection`/`.all`),
  `renderControlCharacters` + `unicodeHighlight`,
  `renderValidationDecorations`, `scrollBeyondLastLine`/`Column`,
  `editorPadding`, `cursorStyle`/`cursorWidth`/`cursorBlinking`/
  `cursorSmoothCaretAnimation` (`.off`/`.on`/`.explicit`),
  `lineNumbersMode` (`.on`/`.off`/`.relative`/`.interval`),
  `lineNumbersMinChars`, `renderBracketPairHighlight`,
  `links` (URL runs open on click), `dragAndDropEnabled`, and
  `readOnlyMessage` (a capsule surfaces it when a read-only edit is
  attempted; `onReadOnlyAttempt` forwards it). Gutter and ruler
  visibility follow the host at runtime.
- **Editing feel**: `occurrencesHighlight` (word under
  the caret washes all its occurrences), `selectionHighlight` (selected
  text washes all its occurrences), `colorDecorators` (inline
  swatches for `#hex`/`rgb()`/`hsl()`), `bracketPairColorization`
  (pairs painted by nesting depth; strings/comments keep their paint),
  and Smart Select (⌃⇧⌘→/←) walking the tree-sitter node ancestry with
  word/line fallbacks.
- **More rendering options**: `renderFinalNewline`
  (on/off/boundary pilcrow), `overviewRulerBorder` +
  `hideCursorInOverviewRuler`, `cursorSurroundingLines` (jump targets
  keep context lines visible), `fontLigatures`, and
  `guides.bracketPairs` (vertical guides spanning pairs, tinted by
  depth).
- **Editing assists** (more Monaco parity): ⌃K delete-to-line-end,
  gutter drag selects whole lines, ⌘⌥Enter / ⌘⌥⇧Enter replace
  one/all while the find bar is up, ⌃-wheel editor zoom
  (`mouseWheelZoom`), and middle-click paste from the find clipboard.
- **Host API**: `onSelectionChange` (line/column/length per caret
  move), `formatSelectionHandler` (⌥⇧F with a selection formats the
  selection only), `onFontScaleChange` (observe editor-local zoom),
  and `actions` (context-menu
  entries with optional key equivalents).
- **Auto formatting**: `formatOnPaste` (⌘V formats the pasted text) and
  `formatOnType` (debounced whole-document format after typing pauses);
  both off by default, manual ⌥⇧F and ⌥⇧⌘V unchanged.
- **Find/replace options**: `seedSearchStringFromSelection`,
  `findLoops`, `findCursorMoveOnType`, `autoFindInSelection` (+ ⌥⌘G to
  toggle find-in-selection live).
- **Language-service hooks** (the subset that makes sense embedded):
  completions (`suggestFactory` + `triggerCharacters`), hovers
  (`hoverProvider`), markers (`markers`), formatting (`formatHandler`),
  definition jumps (`definitionProvider`, F12/⌘-click), document symbols
  (`documentSymbolsProvider`, `⌃⇧O`), signature help (`signatureProvider`,
  `⌃⇧Space` on `(`), tokens (`SyntaxHighlight`).

## Usage

```swift
import Plume
import PlumeLanguages

// At app launch: install your chrome (see the token table below).
EditorTheme.accent = .accentColor
EditorTheme.spaceMedium = 12
// ...

// In a view: bundled presets need no per-language setup.
Editor(
    text: $text,
    annotations: { source in tintedRanges(in: source) },  // optional washes
    syntax: .json,
    suggestFactory: { SuggestBridge() },                  // optional
    placeholder: "Enter a query…")
```

Languages beyond the presets are host-side `SyntaxProfile`s over the
core's walks:

```swift
import Plume

// Define a syntax profile over your grammar (presets cover json, xml, html,
// javascript, bash, lua; other languages are host-side).
extension SyntaxProfile {
    static let toml = SyntaxProfile(
        id: "toml",
        language: { tree_sitter_toml().map { Language($0) } },
        paint: { root, length, cursor, runs in
            myPaintWalk(root, length, &cursor, &runs)   // EditorTheme colors
        },
        commentStyle: .line(prefix: "# "))
}
```

A profile can also carry a block-comment pair so ⇧⌥A (`toggleExplicitBlockComment`)
wraps the selection - supply `blockComment: SyntaxProfile.BlockComment(open: "/*", close: "*/")`
atop a line `commentStyle`. Without it, ⇧⌥A reuses a `.block` `commentStyle`
when present and is a no-op otherwise (JSON, bash).

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
| AppKit fills | `textPrimaryNS` `codeBackgroundNS` `selectionBackgroundNS?` `insertionPointColorNS?` |
| Syntax roles | `syntaxKey` `syntaxString` `syntaxNumber` `syntaxKeyword` `syntaxPlain` `syntaxComment?` `syntaxFunction?` `syntaxVariable?` `syntaxConstant?` |
| Fonts (SwiftUI) | `fontSmall` `fontMonoSubheadline` `fontMonoBody` `fontMonoURLBar` `fontMonoCaption` `fontIconCompact` |
| Metrics | `spaceXSmall` `spaceSmall` `spaceCompact` `spaceMedium` |
| Radii | `radiusSmall` `radiusMedium` |
| Line widths | `lineField` `lineFocusedField` |
| Misc | `toggleControlSize` `opacityDisabled` `motionQuick` |

Colors stay dynamic (light/dark adaptive) after the one-time install.

## Keyboard shortcuts

All bindings are editor-local (they fire while the editor has focus) and
follow Monaco's conventions where they fit macOS. Navigation bindings stay
live in read-only editors; the editing ones need editability.

**Find & replace**

| Shortcut | Action |
|---|---|
| ⌘F / ⌘⌥F | Open find / find with the replace row |
| ⌘G / ⌘⇧G | Next / previous match (retained after the bar is dismissed) |
| ⌘⌥Enter / ⌘⌥⇧Enter | Replace current / replace all (while the bar is up) |
| ⌘⌥E | Use selection for find |
| ⌥⌘G | Toggle find-in-selection, capturing the live selection |
| ↑ / ↓ | Recall query history (find and replace fields) |
| Enter | Next match (find field) / replace current (replace field) |
| Esc | Close the bar |

**Go to & navigation**

| Shortcut | Action |
|---|---|
| ⌥⌘L | Go to line: `12` or `12:5` |
| F12 / ⌘F12 / ⌥F12 | Go to definition |
| ⌘-click | Go to definition |
| ⌃⇧O | Document symbols (outline) |
| ⌃⇧Space | Signature help |
| F8 / ⇧F8 | Next / previous diagnostic |
| ⌃⌘D / ⌃⌘⇧D | Select next / previous occurrence of the word or selection |
| ⌃⇧⌘→ / ⌃⇧⌘← | Smart select: expand / shrink across the tree-sitter node ancestry |
| ⌘⇧\ | Jump to the matching bracket |

**Lines & editing**

| Shortcut | Action |
|---|---|
| ⌘D | Duplicate lines |
| ⌘⇧K | Delete lines |
| ⌃⌘↑ / ⌃⌘↓ | Move lines up / down |
| ⌥⇧↑ / ⌥⇧↓ | Copy lines up / down |
| ⌃K | Delete to line end |
| ⌘⌫ | Delete to the logical line's start |
| ⌘/ | Toggle line comment |
| ⇧⌥A | Toggle block comment (profile's `blockComment`, else a `.block` style) |
| Tab / ⇧Tab | Block indent / outdent (⌘] / ⌘[ work too) |
| ⌃T | Transpose characters |
| → | Hop past a closing bracket/quote the caret sits before |
| Backspace | Between an auto-paired empty pair, deletes both characters |
| ⌘Enter / ⇧⌘Enter | Insert empty line below / above (indent carried) |
| ⌘L | Select the current line (repeat presses grow one line down) |
| ⌘C / ⌘X | With an empty selection, copy / cut the current line |
| Esc | Dismiss completions, then signature help, then the find bar |

**Formatting**

| Shortcut | Action |
|---|---|
| ⌥⇧F | Format the selection, else the document |
| ⌥⇧⌘V | Paste and format |
| ⌘V | Formats the pasted text when `formatOnPaste` is on |

**Zoom & wrap**

| Shortcut | Action |
|---|---|
| ⌃= / ⌃- / ⌃0 | Editor-local zoom in / out / reset (⌃+wheel zooms too) |
| ⌥Z | Toggle word wrap |

Mouse extras: middle-click pastes the find clipboard at the clicked
position. Host-registered `actions` may carry their own key equivalents,
matched by exact modifiers.

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
