import AppKit
import SwiftUI

/// Whitespace-visibility mode.
public enum WhitespaceMode: Equatable, Sendable {
    /// Nothing drawn.
    case none
    /// Every space/tab drawn as a faint middot.
    case all
    /// Only trailing whitespace before the line end, drawn as a faint
    /// middot run (the debug case: invisible tail spaces, \r$).
    case trailing
    /// Whitespace only at line boundaries: the leading indent run and the
    /// trailing run.
    case boundary
    /// Only whitespace inside the current selection.
    case selection
}

/// Final-newline pilcrow mode.
public enum EditorFinalNewlineMode: Equatable, Sendable {
    /// Always draw a faint ¶ at the final newline.
    case on
    /// Never (Plume's historic behavior).
    case off
    /// Only while the caret sits on the last line.
    case boundary
}

/// Selection position snapshot for `onSelectionChange`.
public struct EditorSelectionSnapshot: Equatable, Sendable {
    /// 1-based caret line.
    public let line: Int
    /// 1-based caret column.
    public let column: Int
    /// Selection length in UTF-16 units.
    public let length: Int

    public init(line: Int, column: Int, length: Int) {
        self.line = line
        self.column = column
        self.length = length
    }
}

/// Host-registered action: a context-menu entry
/// with an optional key equivalent, run through the editor's responder.
public struct EditorAction: @unchecked Sendable {
    public let id: String
    public let title: String
    /// Key-equivalent character (e.g. "k"), or nil for menu-only.
    public let key: String?
    /// Exact modifier mask for the key equivalent.
    public let modifiers: NSEvent.ModifierFlags
    public let run: @MainActor @Sendable () -> Void

    public init(
        id: String,
        title: String,
        key: String? = nil,
        modifiers: NSEvent.ModifierFlags = [],
        run: @escaping @MainActor @Sendable () -> Void
    ) {
        self.id = id
        self.title = title
        self.key = key
        self.modifiers = modifiers
        self.run = run
    }
}

/// Line wrapping mode (fill the container, never, or wrap at a
/// column - the `wordWrapColumn`/`bounded` distinction collapsed
/// into one case).
public enum EditorWordWrap: Equatable, Sendable {
    /// Lines fill the container width (the historic default).
    case on
    /// Lines never wrap; the editor scrolls horizontally (and shows the
    /// system's overlay scroller while panning).
    case off
    /// Lines wrap at the given column count (monospace cells).
    case column(Int)
}

/// Caret-line highlight mode.
public enum EditorLineHighlightMode: Equatable, Sendable {
    /// No highlight anywhere.
    case none
    /// Gutter strip only.
    case gutter
    /// Line band only (Plume's historic behavior).
    case line
    /// Both line band and gutter strip.
    case all
}

/// Diagnostic decoration display.
public enum EditorValidationMode: Equatable, Sendable {
    /// Squiggles only while the editor is editable.
    case editable
    /// Always (Plume's historic behavior).
    case on
    /// Never.
    case off
}

/// Whether ⌘F seeds the query from the selection.
public enum EditorSeedSearch: Equatable, Sendable {
    /// Never prefill.
    case never
    /// Always prefill with the (truncated) selection, even multiline.
    case always
    /// Prefill only single-line selections (Plume's historic behavior).
    case selection
}

/// Whether opening find enables “find in selection”.
public enum EditorAutoFindInSelection: Equatable, Sendable {
    /// Never scope to the selection.
    case never
    /// Scope whenever there is a new selection.
    case always
    /// Scope only for multiline selections.
    case multiline
}

/// Insertion-point shape.
public enum EditorCursorStyle: Equatable, Sendable {
    /// System hairline caret (Plume's historic behavior).
    case line
    /// Solid block covering the glyph.
    case block
    /// Underscore at the baseline.
    case underline
}

/// Caret blinking mode.
public enum EditorCursorBlinking: Equatable, Sendable {
    /// System blink (Plume's historic behavior).
    case blink
    /// Steady caret with no blink (custom caret only).
    case solid
}

/// Line-number style for the gutter (Monaco's `editor.lineNumbers`).
public enum EditorLineNumbersMode: Equatable, Sendable {
    /// Absolute line numbers (Plume's historic behavior).
    case on
    /// No line numbers (the gutter collapses like `showsLineNumbers: false`).
    case off
    /// Distance from the caret line; the caret line itself stays absolute.
    case relative
    /// Every 10th line plus the caret line (Monaco's `interval`).
    case interval
}

/// Caret motion smoothing (Monaco's `cursorSmoothCaretAnimation`).
public enum EditorCursorSmoothCaretAnimation: Equatable, Sendable {
    /// Instant caret jumps (Plume's historic behavior).
    case off
    /// Animate every caret move on the same visual line.
    case on
    /// Animate only programmatic jumps (find, go-to-line, diagnostic);
    /// typing stays instant.
    case explicit
}

/// Extra content padding. AppKit's
/// `textContainerInset` is symmetric, so top+bottom collapse into one
/// inset height (extra appears split top/bottom).
public struct EditorPadding: Equatable, Sendable {
    public var top: CGFloat = 0
    public var bottom: CGFloat = 0
    public init(top: CGFloat = 0, bottom: CGFloat = 0) {
        self.top = top
        self.bottom = bottom
    }
}

/// The generic code editor: a standalone NSTextView pipeline with
/// incremental tree-sitter highlighting - each keystroke repaints only the
/// lines the edit (and the parse's changed ranges) touch instead of
/// re-parsing the whole document.
///
/// This is Plume, the shared editor base library. Its files reference nothing outside
/// the package except `EditorTheme` (the chrome seam each host fills in).
/// Host integration is injected, not imported:
/// - syntax via `SyntaxProfile` (package presets or host-defined),
/// - annotation washes via `annotations` (a host tinting pass),
/// - completion via the opaque `EditorSuggestControlling` engine,
/// - formatting via the caller's `formatHandler` (⌥⇧F).
///
/// Editor capabilities: a line-number gutter with error diagnostics, a
/// floating find/replace bar, go-to-line, line operations
/// (duplicate/delete/move), enter-line indent carry, Tab/Shift-Tab indent
/// of the selection, bracket/quote auto-pairing with skip-over and
/// selection wrap, ⌘/ comment toggling per `SyntaxProfile.commentStyle`,
/// read-only selectable mode, placeholder, auto-grow and fill-container
/// sizing, plain-text discipline (no rich text, no smart substitutions),
/// and undo.
public struct Editor: View {
    @Binding var text: String
    /// Annotation provider: given the current text, returns the ranges to
    /// wash with a background color (a host may pass placeholder tints;
    /// nil keeps the editor annotation-free). Read fresh on every paint.
    var annotations: ((String) -> [(NSRange, NSColor)])?
    /// Change-detector for whole-document re-annotation: when this value
    /// differs from the previous update (e.g. the host's annotation scope
    /// changed), the editor re-runs `annotations` over the entire text.
    var restyleKey: String = ""
    var syntax: SyntaxProfile = .plain
    var isEditable: Bool = true
    /// Stretch to the available height (a full-pane editor) instead of
    /// growing with the content between the auto-grow bounds.
    var fillsContainer: Bool = false
    var showsLineNumbers: Bool = true
    /// Vertical hairline between the gutter and the text. Off by default -
    /// the numbers alone read clean against the editor fill.
    var showsGutterSeparator: Bool = false
    /// Code typing assists: enter carries indentation (with brace
    /// expansion), Tab/Shift-Tab indent the selection's lines, ⌘/ toggles
    /// comments. Off for prose/paste surfaces where those are surprises.
    var enablesTypingAssist: Bool = true
    var font: EditorFont = .monoSubheadline
    /// Paragraph line-height multiplier for THIS editor (Monaco's
    /// `lineHeight` option). 1 is the font's natural leading; a host
    /// wanting the balanced font's centered glyph ink passes its
    /// chosen multiple per editor instead of relying on the global
    /// `EditorTheme` default, so two editors in one process can
    /// differ (a multi-line pane vs a tight single-line surface).
    /// Read once at representable creation and refreshed on change
    /// via `restyleKey`-style updates.
    var lineHeightMultiple: CGFloat = 1
    var placeholder: String?
    /// While the editor holds keyboard focus, ⌥⇧F runs its text through
    /// this handler as one undoable step. Returns the formatted text, nil
    /// when already formatted, or throws the diagnostic. Read fresh on
    /// every invocation.
    var formatHandler: ((String) throws -> String?)?
    /// Undo-menu label for the ⌥⇧F step ("Format Script", "Format Body").
    var formatActionName: String = "Format"
    /// Receives a format handler's diagnostic when ⌥⇧F hits text that does
    /// not parse (the transient bottom capsule of the caller).
    var onFormatError: ((String) -> Void)?
    /// Creates the editor's completion engine, called once per view
    /// lifetime (the engine outlives SwiftUI re-renders inside the
    /// coordinator). Nil runs the editor without completion support.
    var suggestFactory: (() -> any EditorSuggestControlling)?
    /// Opaque candidate payload forwarded to the engine on every update
    /// (the engine casts; the editor never inspects it). The host passes
    /// its current render's candidates so an open popup re-filters live.
    var suggestItems: [Any] = []
    /// Cursor/status callback: fired on selection changes and after edits
    /// with the document's size and the caret's position (1-based line and
    /// column, matching gutter numbering), plus the document stats.
    var onStatsChange: ((Editor.Stats) -> Void)?
    /// Hover content provider: given the character range under the pointer,
    /// returns the tooltip text (nil = no hover). Diagnostics carry their own tooltips which
    /// win when both apply; the provider is consulted only off-diagnostics.
    var hoverProvider: ((_ range: NSRange) -> String?)?
    /// Definition provider: given the token range under the caret (or the
    /// click location for ⌘-click), returns the definition's range in the
    /// same document (nil = nowhere to jump). F12 and ⌘-click jump when
    /// set; nil (historic) keeps both as no-ops.
    var definitionProvider: ((_ range: NSRange) -> NSRange?)?
    /// Bracket/quote auto-pairing (insert the closing character, skip over,
    /// wrap the selection). Off for paste/import surfaces where inserted
    /// closers are surprises. Independent of `enablesTypingAssist` (indent
    /// and comments), because pairing alone is what pollutes pastes.
    var enablesAutoPairing: Bool = true
    /// Visible-whitespace rendering. Trailing
    /// covers the debug-gem cases (JSON tail spaces, RESP line endings)
    /// without the noise of dotting every indent.
    var renderWhitespace: WhitespaceMode = .none
    /// Host-injected diagnostics: squiggles,
    /// gutter dots, and tooltips rendered alongside the parse's own syntax
    /// errors. Read fresh on every host update; ranges are UTF-16 against
    /// the current text.
    var markers: [EditorMarker] = []
    /// The overview ruler: a narrow strip
    /// right of the text with marker ticks and a viewport band, doubling
    /// as the scroll affordance (click/drag scrolls). Off for compact
    /// editors; worth its 14pt in full-pane surfaces.
    var showsOverviewRuler: Bool = false
    /// Spaces per indent level; also the tab stop
    /// width for literal tab characters. Defaults to Plume's historic 2.
    var tabSize: Int = 2
    /// Indent with spaces when true, tab
    /// characters when false.
    var insertSpaces: Bool = true
    /// Infer `tabSize`/`insertSpaces` from the document's leading
    /// whitespace on first fill; the
    /// host-passed values are the fallback. Off by default (Plume's
    /// surfaces are single-purpose bodies, not arbitrary files).
    var detectIndentation: Bool = false
    /// Line wrapping. `.on` keeps the historic
    /// fill-the-container behavior; `.off`/`.column(_)` scroll or wrap
    /// horizontally instead.
    var wordWrap: EditorWordWrap = .on
    /// Column ruler(s), drawn as hairlines.
    var rulers: [Int] = []
    /// Caret-line highlight.
    var renderLineHighlight: EditorLineHighlightMode = .line
    /// Only render the line highlight while the editor has focus.
    var renderLineHighlightOnlyWhenFocus: Bool = false
    /// Allow scrolling past the last line by a viewport.
    var scrollBeyondLastLine: Bool = false
    /// Extra right-hand scroll runway in points (right padding).
    var scrollBeyondLastColumn: CGFloat = 0
    /// Content top/bottom padding.
    var editorPadding: EditorPadding = EditorPadding()
    /// Draw control characters as boxes.
    var renderControlCharacters: Bool = false
    /// Underline ambiguous unicode (bidi/zero-width controls).
    var unicodeHighlight: Bool = false
    /// Word-under-caret occurrence wash. Off keeps the historic selection-only
    /// highlight.
    var occurrencesHighlight: Bool = false
    /// Inline color swatches.
    var colorDecorators: Bool = false
    /// Bracket pairs painted by nesting depth.
    var bracketPairColorization: Bool = false
    /// Diagnostic squiggle display.
    var renderValidationDecorations: EditorValidationMode = .on
    /// Message shown when the user types into a read-only editor.
    var readOnlyMessage: String?
    /// Fired with `readOnlyMessage` when a read-only edit is attempted.
    var onReadOnlyAttempt: ((String) -> Void)?
    /// Automatic link detection. Off keeps Plume's
    /// historic behavior.
    var linksEnabled: Bool = false
    /// Accept drag-and-drop drops onto the text.
    var dragAndDropEnabled: Bool = true
    /// Final-newline pilcrow.
    var renderFinalNewline: EditorFinalNewlineMode = .off
    /// Hairline between text and the overview ruler.
    var overviewRulerBorder: Bool = true
    /// Hide the caret tick in the overview ruler.
    var hideCursorInOverviewRuler: Bool = false
    /// Lines kept visible around the caret on jumps.
    /// Zero keeps the historic behavior.
    var cursorSurroundingLines: Int = 0
    /// Common ligatures on the text font.
    var fontLigatures: Bool = false
    /// Vertical guides spanning bracket pairs.
    var bracketGuides: Bool = false
    /// Vertical guides at every completed indent level.
    var indentGuides: Bool = true
    /// Fires on every selection change.
    var onSelectionChange: ((EditorSelectionSnapshot) -> Void)?
    /// Formats the SELECTED text; ⌥⇧F with a
    /// selection routes here before the whole-document handler.
    var formatSelectionHandler: ((String) throws -> String?)?
    /// Host-registered actions: context-menu
    /// entries with optional key equivalents.
    var actions: [EditorAction] = []
    /// Insertion-point shape. `.line` is the
    /// system caret.
    var cursorStyle: EditorCursorStyle = .line
    /// Caret thickness in points; 0 = system hairline.
    var cursorWidth: CGFloat = 0
    /// Caret blinking.
    var cursorBlinking: EditorCursorBlinking = .blink
    /// Find seeding.
    var seedSearchStringFromSelection: EditorSeedSearch = .selection
    /// Wrap-around for Next/Previous.
    var findLoops: Bool = true
    /// Move the caret to the first match while typing a query.
    var findCursorMoveOnType: Bool = true
    /// Auto-enable find-in-selection on open.
    var autoFindInSelection: EditorAutoFindInSelection = .never
    /// Line-number style. `.on` preserves the historic absolute
    /// numbering; `showsLineNumbers` stays as the visibility gate.
    var lineNumbersMode: EditorLineNumbersMode = .on
    /// Caret smoothing. `.off` preserves instant jumps.
    var cursorSmoothCaretAnimation: EditorCursorSmoothCaretAnimation = .off
    /// Format whatever the user pastes through `formatHandler` (minified
    /// JSON pastes pretty-printed). Off keeps plain pastes.
    var formatOnPaste: Bool = false
    /// Debounced whole-document formatting shortly after typing pauses
    /// (800ms idle). Off keeps manual `⌥⇧F` only.
    var formatOnType: Bool = false
    /// Starting font scale for the editor-local zoom (Monaco's
    /// `editorZoom`). 1 is the `font` size itself; `⌃=`/`⌃⌥-` adjust
    /// the live scale afterwards. Host changes after creation do not
    /// reset the live zoom.
    var initialFontScale: CGFloat = 1
    /// Observe zoom changes (for persistence); nil keeps zoom local.
    var onFontScaleChange: ((CGFloat) -> Void)?
    /// Document-symbol provider for the outline (`⌃⇧O`). Given the
    /// current text, returns the symbols in document order. Nil uses
    /// the built-in tree-sitter extraction (functions/classes/variables,
    /// JSON keys).
    var documentSymbolsProvider: ((_ text: String) -> [EditorDocumentSymbol])?
    /// Signature-help provider (Monaco `SignatureHelp`): given the
    /// function-name range and the active parameter, returns the
    /// signature to show (nil = nothing). Nil disables the popup.
    var signatureProvider: ((_ functionRange: NSRange, _ activeParameter: Int) -> EditorSignatureHelp?)?
    /// Minimum gutter digits for line numbers (Monaco
    /// `lineNumbersMinChars`). 0 keeps the historic digit-width fit; a
    /// larger value pins a wider strip so digits never reflow.
    var lineNumbersMinChars: Int = 0
    /// Background wash on the matching bracket pair (Monaco
    /// `bracketPairHighlight`). Off keeps foreground-only highlight.
    var renderBracketPairHighlight: Bool = false
    /// Wash every occurrence of the selected text (Monaco
    /// `selectionHighlight`). Off keeps word-only selection highlight.
    var selectionHighlight: Bool = false
    /// Observe word-wrap toggles (`⌥Z`); nil keeps the toggle local.
    var onWordWrapChange: ((EditorWordWrap) -> Void)?

    /// A point-in-time snapshot of the document's size and caret position.
    public struct Stats: Equatable, Sendable {
        /// Total lines (the trailing phantom line counts, like the gutter).
        public let lines: Int
        /// Total characters (UTF-16 count, i.e. `string.count`).
        public let characters: Int
        /// The caret's 1-based line.
        public let line: Int
        /// The caret's 1-based column (in characters).
        public let column: Int
    }

    /// Text view insets: the container inset plus the per-fragment padding
    /// make the text origin - the placeholder overlay matches it exactly.
    /// The container's `lineFragmentPadding` is zeroed (set on the text
    /// container at setup) so the fragment rects align flush with the text
    /// origin - the current-line band and selection highlight then share
    /// identical left/right edges (AppKit's default 5pt padding made the
    /// band poke out blank on both sides of a selection).
    static let textInset = NSSize(width: 6, height: 6)
    static let fragmentPadding: CGFloat = 5

    /// Auto-grow bounds (fillsContainer = false): the frame grows with the
    /// content between these bounds. Hosts pick per surface - small fields
    /// keep a tight cap; code panes should use fillsContainer instead.
    var autoGrowMinHeight: CGFloat = 40
    var autoGrowMaxHeight: CGFloat = 96

    @State private var contentHeight: CGFloat = 40
    /// Live gutter width (line-count digits), synced from updateNSView so
    /// the placeholder clears the strip.
    @State private var gutterWidth: CGFloat = 0
    /// Editor-local find/replace state; the find bar overlays the top edge
    /// and the coordinator mirrors the query into its match pass.
    @State private var findState = EditorFindState()
    @State private var findPendingAction: EditorFindAction?
    /// Match count + selected index, pushed back from the coordinator.
    @State private var findCount = 0
    @State private var findIndex: Int?
    /// Go-to-line panel (⌥⌘L); mutually exclusive with the find bar.
    @State private var gotoVisible = false
    @State private var gotoText = ""
    @State private var gotoPendingLine: Int?
    @State private var gotoPendingColumn: Int?
    /// Total lines, pushed back for the go-to-line prompt.
    @State private var lineCountHint = 1
    /// Live zoom factor; seeded from `initialFontScale` at creation.
    @State private var fontScale: CGFloat = 1
    /// Recent find/replace queries (most-recent-first, capped) for
    /// Up/Down navigation in the bar. Editor-local; never hits storage.
    @State private var queryHistory: [String] = []
    @State private var replacementHistory: [String] = []
    /// Document-outline panel (⌃⇧O); mutually exclusive with find/goto.
    @State private var outlineVisible = false
    @State private var outlineQuery = ""
    @State private var outlineSymbols: [EditorDocumentSymbol] = []
    @State private var outlineSelectedIndex = 0
    @State private var outlinePendingRange: NSRange?
    /// Filtered symbols the outline bar renders.
    private var outlineFilteredSymbols: [EditorDocumentSymbol] {
        DocumentSymbolFilter.filtered(outlineSymbols, by: outlineQuery)
    }
    /// Editor-local word-wrap override (`⌥Z`); nil follows the host prop.
    @State private var wordWrapOverride: EditorWordWrap?
    /// The wrap mode the editor actually renders.
    private var effectiveWordWrap: EditorWordWrap { wordWrapOverride ?? wordWrap }

    /// Creates the editor. Every parameter beyond `text` is optional;
    /// pass only what the host needs (a plain read-write editor is
    /// `Editor(text: $text)`).
    public init(
        text: Binding<String>,
        annotations: ((String) -> [(NSRange, NSColor)])? = nil,
        restyleKey: String = "",
        syntax: SyntaxProfile = .plain,
        isEditable: Bool = true,
        fillsContainer: Bool = false,
        showsLineNumbers: Bool = true,
        showsGutterSeparator: Bool = false,
        enablesTypingAssist: Bool = true,
        font: EditorFont = .monoSubheadline,
        lineHeightMultiple: CGFloat = 1,
        placeholder: String? = nil,
        formatHandler: ((String) throws -> String?)? = nil,
        formatActionName: String = "Format",
        onFormatError: ((String) -> Void)? = nil,
        suggestFactory: (() -> any EditorSuggestControlling)? = nil,
        suggestItems: [Any] = [],
        onStatsChange: ((Editor.Stats) -> Void)? = nil,
        hoverProvider: ((_ range: NSRange) -> String?)? = nil,
        enablesAutoPairing: Bool = true,
        renderWhitespace: WhitespaceMode = .none,
        markers: [EditorMarker] = [],
        showsOverviewRuler: Bool = false,
        tabSize: Int = 2,
        insertSpaces: Bool = true,
        detectIndentation: Bool = false,
        wordWrap: EditorWordWrap = .on,
        rulers: [Int] = [],
        renderLineHighlight: EditorLineHighlightMode = .line,
        renderLineHighlightOnlyWhenFocus: Bool = false,
        scrollBeyondLastLine: Bool = false,
        scrollBeyondLastColumn: CGFloat = 0,
        editorPadding: EditorPadding = EditorPadding(),
        renderControlCharacters: Bool = false,
        unicodeHighlight: Bool = false,
        occurrencesHighlight: Bool = false,
        colorDecorators: Bool = false,
        bracketPairColorization: Bool = false,
        renderValidationDecorations: EditorValidationMode = .on,
        readOnlyMessage: String? = nil,
        onReadOnlyAttempt: ((String) -> Void)? = nil,
        linksEnabled: Bool = false,
        dragAndDropEnabled: Bool = true,
        renderFinalNewline: EditorFinalNewlineMode = .off,
        overviewRulerBorder: Bool = true,
        hideCursorInOverviewRuler: Bool = false,
        cursorSurroundingLines: Int = 0,
        fontLigatures: Bool = false,
        bracketGuides: Bool = false,
        indentGuides: Bool = true,
        onSelectionChange: ((EditorSelectionSnapshot) -> Void)? = nil,
        formatSelectionHandler: ((String) throws -> String?)? = nil,
        actions: [EditorAction] = [],
        cursorStyle: EditorCursorStyle = .line,
        cursorWidth: CGFloat = 0,
        cursorBlinking: EditorCursorBlinking = .blink,
        seedSearchStringFromSelection: EditorSeedSearch = .selection,
        findLoops: Bool = true,
        findCursorMoveOnType: Bool = true,
        autoFindInSelection: EditorAutoFindInSelection = .never,
        autoGrowMinHeight: CGFloat = 40,
        autoGrowMaxHeight: CGFloat = 96,
        lineNumbersMode: EditorLineNumbersMode = .on,
        cursorSmoothCaretAnimation: EditorCursorSmoothCaretAnimation = .off,
        formatOnPaste: Bool = false,
        formatOnType: Bool = false,
        initialFontScale: CGFloat = 1,
        onFontScaleChange: ((CGFloat) -> Void)? = nil,
        definitionProvider: ((_ range: NSRange) -> NSRange?)? = nil,
        documentSymbolsProvider: ((_ text: String) -> [EditorDocumentSymbol])? = nil,
        signatureProvider: ((_ functionRange: NSRange, _ activeParameter: Int) -> EditorSignatureHelp?)? = nil,
        lineNumbersMinChars: Int = 0,
        renderBracketPairHighlight: Bool = false,
        selectionHighlight: Bool = false,
        onWordWrapChange: ((EditorWordWrap) -> Void)? = nil
    ) {
        self._text = text
        self.annotations = annotations
        self.restyleKey = restyleKey
        self.syntax = syntax
        self.isEditable = isEditable
        self.fillsContainer = fillsContainer
        self.autoGrowMinHeight = autoGrowMinHeight
        self.autoGrowMaxHeight = autoGrowMaxHeight
        self.showsLineNumbers = showsLineNumbers
        self.showsGutterSeparator = showsGutterSeparator
        self.enablesTypingAssist = enablesTypingAssist
        self.font = font
        self.lineHeightMultiple = lineHeightMultiple
        self.placeholder = placeholder
        self.formatHandler = formatHandler
        self.formatActionName = formatActionName
        self.onFormatError = onFormatError
        self.suggestFactory = suggestFactory
        self.suggestItems = suggestItems
        self.onStatsChange = onStatsChange
        self.hoverProvider = hoverProvider
        self.enablesAutoPairing = enablesAutoPairing
        self.renderWhitespace = renderWhitespace
        self.markers = markers
        self.showsOverviewRuler = showsOverviewRuler
        self.tabSize = tabSize
        self.insertSpaces = insertSpaces
        self.detectIndentation = detectIndentation
        self.wordWrap = wordWrap
        self.rulers = rulers
        self.renderLineHighlight = renderLineHighlight
        self.renderLineHighlightOnlyWhenFocus = renderLineHighlightOnlyWhenFocus
        self.scrollBeyondLastLine = scrollBeyondLastLine
        self.scrollBeyondLastColumn = scrollBeyondLastColumn
        self.editorPadding = editorPadding
        self.renderControlCharacters = renderControlCharacters
        self.unicodeHighlight = unicodeHighlight
        self.occurrencesHighlight = occurrencesHighlight
        self.colorDecorators = colorDecorators
        self.bracketPairColorization = bracketPairColorization
        self.renderValidationDecorations = renderValidationDecorations
        self.readOnlyMessage = readOnlyMessage
        self.onReadOnlyAttempt = onReadOnlyAttempt
        self.linksEnabled = linksEnabled
        self.dragAndDropEnabled = dragAndDropEnabled
        self.renderFinalNewline = renderFinalNewline
        self.overviewRulerBorder = overviewRulerBorder
        self.hideCursorInOverviewRuler = hideCursorInOverviewRuler
        self.cursorSurroundingLines = cursorSurroundingLines
        self.fontLigatures = fontLigatures
        self.bracketGuides = bracketGuides
        self.indentGuides = indentGuides
        self.onSelectionChange = onSelectionChange
        self.formatSelectionHandler = formatSelectionHandler
        self.actions = actions
        self.cursorStyle = cursorStyle
        self.cursorWidth = cursorWidth
        self.cursorBlinking = cursorBlinking
        self.seedSearchStringFromSelection = seedSearchStringFromSelection
        self.findLoops = findLoops
        self.findCursorMoveOnType = findCursorMoveOnType
        self.autoFindInSelection = autoFindInSelection
        self.lineNumbersMode = lineNumbersMode
        self.cursorSmoothCaretAnimation = cursorSmoothCaretAnimation
        self.formatOnPaste = formatOnPaste
        self.formatOnType = formatOnType
        self.initialFontScale = initialFontScale
        self.onFontScaleChange = onFontScaleChange
        self.definitionProvider = definitionProvider
        self.documentSymbolsProvider = documentSymbolsProvider
        self.signatureProvider = signatureProvider
        self.lineNumbersMinChars = lineNumbersMinChars
        self.renderBracketPairHighlight = renderBracketPairHighlight
        self.selectionHighlight = selectionHighlight
        self.onWordWrapChange = onWordWrapChange
        self._fontScale = State(initialValue: Self.normalizedFontScale(initialFontScale))
    }

    /// Clamps a zoom factor into the supported range (invalid → 1).
    static func normalizedFontScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite, scale > 0 else { return 1 }
        return min(max(scale, 0.5), 4)
    }

    /// Records `value` as the most-recent history entry (skips empties
    /// and immediate duplicates, capped at 20, editor-local).
    static func recordHistory(_ history: inout [String], value: String) {
        guard !value.isEmpty, history.first != value else { return }
        history.removeAll { $0 == value }
        history.insert(value, at: 0)
        if history.count > 20 { history = Array(history.prefix(20)) }
    }

    /// The `font` at the live zoom factor. At 1:1 this equals `font`.
    private var effectiveFont: EditorFont {
        let scale = Self.normalizedFontScale(fontScale)
        guard scale != 1 else { return font }
        return EditorFont(size: font.size * scale, weight: font.weight, monospaced: font.monospaced)
    }

    /// Transient read-only notice.
    @State private var readOnlyNotice: String?

    public var body: some View {
        EditorRepresentable(
            text: $text,
            annotations: annotations,
            restyleKey: restyleKey,
            syntax: syntax,
            isEditable: isEditable,
            fillsContainer: fillsContainer,
            showsLineNumbers: showsLineNumbers,
            showsGutterSeparator: showsGutterSeparator,
            enablesTypingAssist: enablesTypingAssist,
            font: effectiveFont,
            lineHeightMultiple: lineHeightMultiple,
            formatHandler: formatHandler,
            formatActionName: formatActionName,
            onFormatError: onFormatError,
            suggestFactory: suggestFactory,
            suggestItems: suggestItems,
            onStatsChange: onStatsChange,
            hoverProvider: hoverProvider,
            enablesAutoPairing: enablesAutoPairing,
            renderWhitespace: renderWhitespace,
            markers: markers,
            showsOverviewRuler: showsOverviewRuler,
            tabSize: tabSize,
            insertSpaces: insertSpaces,
            detectIndentation: detectIndentation,
            wordWrap: effectiveWordWrap,
            rulers: rulers,
            renderLineHighlight: renderLineHighlight,
            renderLineHighlightOnlyWhenFocus: renderLineHighlightOnlyWhenFocus,
            scrollBeyondLastLine: scrollBeyondLastLine,
            scrollBeyondLastColumn: scrollBeyondLastColumn,
            editorPadding: editorPadding,
            renderControlCharacters: renderControlCharacters,
            unicodeHighlight: unicodeHighlight,
            occurrencesHighlight: occurrencesHighlight,
            colorDecorators: colorDecorators,
            bracketPairColorization: bracketPairColorization,
            renderValidationDecorations: renderValidationDecorations,
            readOnlyMessage: readOnlyMessage,
            onReadOnlyAttempt: onReadOnlyAttempt,
            onReadOnlyAttemptNotice: { message in
                DispatchQueue.main.async { readOnlyNotice = message }
            },
            linksEnabled: linksEnabled,
            dragAndDropEnabled: dragAndDropEnabled,
            renderFinalNewline: renderFinalNewline,
            overviewRulerBorder: overviewRulerBorder,
            hideCursorInOverviewRuler: hideCursorInOverviewRuler,
            cursorSurroundingLines: cursorSurroundingLines,
            fontLigatures: fontLigatures,
            bracketGuides: bracketGuides,
            indentGuides: indentGuides,
            onSelectionChange: onSelectionChange,
            formatSelectionHandler: formatSelectionHandler,
            actions: actions,
            cursorStyle: cursorStyle,
            cursorWidth: cursorWidth,
            cursorBlinking: cursorBlinking,
            seedSearchStringFromSelection: seedSearchStringFromSelection,
            findLoops: findLoops,
            findCursorMoveOnType: findCursorMoveOnType,
            autoFindInSelection: autoFindInSelection,
            lineNumbersMode: lineNumbersMode,
            cursorSmoothCaretAnimation: cursorSmoothCaretAnimation,
            formatOnPaste: formatOnPaste,
            formatOnType: formatOnType,
            fontScale: Self.normalizedFontScale(fontScale),
            onFontScaleChange: { newScale in
                let normalized = Self.normalizedFontScale(newScale)
                fontScale = normalized
                onFontScaleChange?(normalized)
            },
            definitionProvider: definitionProvider,
            documentSymbolsProvider: documentSymbolsProvider,
            signatureProvider: signatureProvider,
            onDocumentSymbolsChanged: { symbols in
                DispatchQueue.main.async {
                    outlineSymbols = symbols
                    outlineQuery = ""
                    outlineSelectedIndex = 0
                    outlineVisible = !symbols.isEmpty
                    findState.visible = false
                    gotoVisible = false
                }
            },
            outlinePendingRange: outlinePendingRange,
            onOutlinePendingHandled: { outlinePendingRange = nil },
            outlineVisible: outlineVisible,
            lineNumbersMinChars: lineNumbersMinChars,
            renderBracketPairHighlight: renderBracketPairHighlight,
            selectionHighlight: selectionHighlight,
            onWordWrapChange: { newMode in
                wordWrapOverride = newMode
                onWordWrapChange?(newMode)
            },
            onContentHeightChange: fillsContainer
                ? nil
                : { newHeight in
                    // updateNSView runs inside SwiftUI's update transaction,
                    // where a synchronous @State write is silently dropped.
                    // Defer one runloop so it applies; ordering is FIFO.
                    DispatchQueue.main.async { contentHeight = newHeight }
                },
            onGutterWidthChange: { newWidth in
                DispatchQueue.main.async { gutterWidth = newWidth }
            },
            find: findState,
            findAction: findPendingAction,
            onFindActionHandled: { findPendingAction = nil },
            findHooks: EditorFindHooks(
                requested: { selection, scope, replaceMode in
                    findState.visible = true
                    findState.replacing = replaceMode
                    if let selection, !selection.isEmpty { findState.query = selection }
                    if let scope {
                        findState.inSelection = true
                        findState.scopeLocation = scope.location
                        findState.scopeLength = scope.length
                        findState.replacing = replaceMode
                    } else if autoFindInSelection == .never {
                        findState.inSelection = false
                    }
                    gotoVisible = false
                    outlineVisible = false
                },
                countChanged: { count, index in
                    findCount = count
                    findIndex = index
                },
                closed: { findState.visible = false },
                useSelection: { selected in
                    findState.query = selected
                },
                linePanel: {
                    gotoVisible = true
                    gotoText = ""
                    findState.visible = false
                    outlineVisible = false
                }
            ),
            gotoLine: gotoPendingLine,
            gotoColumn: gotoPendingColumn,
            onGoToLineHandled: {
                gotoPendingLine = nil
                gotoPendingColumn = nil
            },
            onLineCountHint: { lineCountHint = $0 },
            gotoVisible: gotoVisible
        )
        .overlay(alignment: .topTrailing) {
            ZStack(alignment: .topTrailing) {
                if findState.visible {
                    EditorFindBar(
                        query: $findState.query,
                        replacement: $findState.replacement,
                        caseSensitive: $findState.caseSensitive,
                        isRegex: $findState.isRegex,
                        wholeWord: $findState.wholeWord,
                        preserveCase: $findState.preserveCase,
                        replacing: $findState.replacing,
                        matchCount: findCount,
                        matchIndex: findIndex,
                        isEditable: isEditable,
                        queryHistory: queryHistory,
                        replacementHistory: replacementHistory,
                        onNext: {
                            Self.recordHistory(&queryHistory, value: findState.query)
                            findPendingAction = .next
                        },
                        onPrevious: {
                            Self.recordHistory(&queryHistory, value: findState.query)
                            findPendingAction = .previous
                        },
                        onReplace: {
                            Self.recordHistory(&queryHistory, value: findState.query)
                            Self.recordHistory(&replacementHistory, value: findState.replacement)
                            findPendingAction = .replaceCurrent
                        },
                        onReplaceAll: {
                            Self.recordHistory(&queryHistory, value: findState.query)
                            Self.recordHistory(&replacementHistory, value: findState.replacement)
                            findPendingAction = .replaceAll
                        },
                        onClose: {
                            Self.recordHistory(&queryHistory, value: findState.query)
                            Self.recordHistory(&replacementHistory, value: findState.replacement)
                            findState.visible = false
                        }
                    )
                    .padding(.trailing, EditorTheme.spaceMedium)
                    .padding(.top, EditorTheme.spaceXSmall)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if gotoVisible {
                    EditorGoToLineBar(
                        text: $gotoText,
                        lineCount: lineCountHint,
                        onClose: { gotoVisible = false },
                        onSubmit: {
                            if let parsed = EditorGoToLineBar.parse(gotoText) {
                                gotoPendingLine = parsed.line
                                gotoPendingColumn = parsed.column
                            }
                            gotoVisible = false
                        }
                    )
                    .padding(.trailing, EditorTheme.spaceMedium)
                    .padding(.top, EditorTheme.spaceXSmall)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if outlineVisible {
                    EditorDocumentSymbolsBar(
                        query: $outlineQuery,
                        symbols: outlineFilteredSymbols,
                        selectedIndex: $outlineSelectedIndex,
                        onClose: { outlineVisible = false },
                        onPick: { symbol in
                            outlinePendingRange = symbol.range
                            outlineVisible = false
                        }
                    )
                    .padding(.trailing, EditorTheme.spaceMedium)
                    .padding(.top, EditorTheme.spaceXSmall)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .frame(
            height: fillsContainer
                ? nil
                : min(max(contentHeight, autoGrowMinHeight), autoGrowMaxHeight),
            alignment: .topLeading
        )
        .overlay(alignment: .bottomTrailing) {
            if let notice = readOnlyNotice {
                Text(notice)
                    .font(effectiveFont.swiftUIFont)
                    .foregroundStyle(EditorTheme.textPrimary)
                    .padding(.horizontal, EditorTheme.spaceSmall)
                    .padding(.vertical, EditorTheme.spaceXSmall)
                    .background(EditorTheme.subtleBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(EditorTheme.border, lineWidth: EditorTheme.lineField)
                    )
                    .padding(.trailing, EditorTheme.spaceMedium)
                    .padding(.bottom, EditorTheme.spaceSmall)
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.15), value: readOnlyNotice)
            }
        }
        .overlay(alignment: .topLeading) {
            if text.isEmpty, let placeholder, !findState.visible {
                Text(placeholder)
                    .font(effectiveFont.swiftUIFont)
                    .foregroundStyle(EditorTheme.tertiaryText)
                    .padding(.leading, Self.textInset.width + Self.fragmentPadding + gutterWidth)
                    .padding(.top, Self.textInset.height + editorPadding.top)
                    .animation(.easeInOut(duration: 0.15), value: gutterWidth)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: readOnlyNotice) { _, notice in
            guard notice != nil else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                readOnlyNotice = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            readOnlyNotice = nil
        }
    }
}

// MARK: - AppKit bridge

/// Opaque completion engine attached to a `Editor`. The editor
/// treats the engine as a black box: it forwards edit/selection/command
/// traffic and the host's candidate payload, and asks nothing about what
/// the candidates are. The host bridges its own completion controller
/// onto this; a host without completion support simply passes no factory.
@MainActor
public protocol EditorSuggestControlling: AnyObject {
    /// The candidate universe changed; the engine re-evaluates an open
    /// session. The payload is opaque - the engine casts it.
    func candidatesChanged(_ candidates: [Any])
    func textChanged(_ textView: NSTextView)
    func selectionChanged(_ textView: NSTextView)
    /// Returns true when the selector was consumed by an open session.
    func handleCommand(_ selector: Selector) -> Bool
    var isVisible: Bool { get }
    func hide()
    /// ⌥⎋ (Monaco `triggerSuggest`): the host opens its completion popup
    /// at the caret. Returns true when a popup was shown. Hosts without a
    /// completion UI need not implement it - the default returns false
    /// and ⌥⎋ falls back to AppKit word completion.
    func triggerSuggest(in textView: NSTextView) -> Bool
}

extension EditorSuggestControlling {
    public func triggerSuggest(in textView: NSTextView) -> Bool { false }
}

struct EditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    let annotations: ((String) -> [(NSRange, NSColor)])?
    let restyleKey: String
    let syntax: SyntaxProfile
    let isEditable: Bool
    let fillsContainer: Bool
    let showsLineNumbers: Bool
    let showsGutterSeparator: Bool
    let enablesTypingAssist: Bool
    let font: EditorFont
    let lineHeightMultiple: CGFloat
    let formatHandler: ((String) throws -> String?)?
    let formatActionName: String
    let onFormatError: ((String) -> Void)?
    let suggestFactory: (() -> any EditorSuggestControlling)?
    let suggestItems: [Any]
    let onStatsChange: ((Editor.Stats) -> Void)?
    let hoverProvider: ((_ range: NSRange) -> String?)?
    let enablesAutoPairing: Bool
    let renderWhitespace: WhitespaceMode
    let markers: [EditorMarker]
    let showsOverviewRuler: Bool
    let tabSize: Int
    let insertSpaces: Bool
    let detectIndentation: Bool
    let wordWrap: EditorWordWrap
    var rulers: [Int] = []
    var renderLineHighlight: EditorLineHighlightMode = .line
    var renderLineHighlightOnlyWhenFocus: Bool = false
    var scrollBeyondLastLine: Bool = false
    var scrollBeyondLastColumn: CGFloat = 0
    var editorPadding: EditorPadding = EditorPadding()
    var renderControlCharacters: Bool = false
    var unicodeHighlight: Bool = false
    /// Word under the caret (empty selection) highlights all its
    /// occurrences. Selected-text
    /// highlighting is the historic behavior and stays always on.
    var occurrencesHighlight: Bool = false
    /// Inline color swatches before `#hex`/`rgb()`/`hsl()` tokens.
    var colorDecorators: Bool = false
    /// Bracket pairs painted by nesting depth;
    /// strings/comments keep their own paint.
    var bracketPairColorization: Bool = false
    var renderValidationDecorations: EditorValidationMode = .on
    var readOnlyMessage: String?
    var onReadOnlyAttempt: ((String) -> Void)?
    /// Internal bridge: shows `readOnlyMessage` in the editor's own
    /// capsule when a read-only edit is attempted.
    var onReadOnlyAttemptNotice: ((String) -> Void)?
    var linksEnabled: Bool = false
    var dragAndDropEnabled: Bool = true
    var renderFinalNewline: EditorFinalNewlineMode = .off
    var overviewRulerBorder: Bool = true
    var hideCursorInOverviewRuler: Bool = false
    var cursorSurroundingLines: Int = 0
    var fontLigatures: Bool = false
    var bracketGuides: Bool = false
    var indentGuides: Bool = true
    var onSelectionChange: ((EditorSelectionSnapshot) -> Void)?
    var formatSelectionHandler: ((String) throws -> String?)?
    var actions: [EditorAction] = []
    var cursorStyle: EditorCursorStyle = .line
    var cursorWidth: CGFloat = 0
    var cursorBlinking: EditorCursorBlinking = .blink
    var seedSearchStringFromSelection: EditorSeedSearch = .selection
    var findLoops: Bool = true
    var findCursorMoveOnType: Bool = true
    var autoFindInSelection: EditorAutoFindInSelection = .never
    var lineNumbersMode: EditorLineNumbersMode = .on
    var cursorSmoothCaretAnimation: EditorCursorSmoothCaretAnimation = .off
    var formatOnPaste: Bool = false
    var formatOnType: Bool = false
    var fontScale: CGFloat = 1
    var onFontScaleChange: ((CGFloat) -> Void)?
    var definitionProvider: ((_ range: NSRange) -> NSRange?)?
    var documentSymbolsProvider: ((_ text: String) -> [EditorDocumentSymbol])?
    var signatureProvider: ((_ functionRange: NSRange, _ activeParameter: Int) -> EditorSignatureHelp?)?
    var onDocumentSymbolsChanged: (([EditorDocumentSymbol]) -> Void)?
    var outlinePendingRange: NSRange?
    var onOutlinePendingHandled: (() -> Void)?
    var outlineVisible: Bool = false
    var lineNumbersMinChars: Int = 0
    var renderBracketPairHighlight: Bool = false
    var selectionHighlight: Bool = false
    var onWordWrapChange: ((EditorWordWrap) -> Void)?
    let onContentHeightChange: ((CGFloat) -> Void)?
    let onGutterWidthChange: ((CGFloat) -> Void)?
    let find: EditorFindState
    let findAction: EditorFindAction?
    let onFindActionHandled: (() -> Void)?
    let findHooks: EditorFindHooks?
    let gotoLine: Int?
    let gotoColumn: Int?
    let onGoToLineHandled: (() -> Void)?
    let onLineCountHint: ((Int) -> Void)?
    /// Whether the go-to-line panel is up (the find bar's visibility lives
    /// in `find`); the cursor exclusion covers whichever bar is up.
    var gotoVisible: Bool = false

    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(self)
    }

    /// Sizing like the NSScrollView this editor replaced: accept whatever
    /// the stack proposes (falls back to the constraint-derived fitting
    /// size only when a dimension is unconstrained). The default NSView
    /// sizing reports the constraint minimum (gutter width × 0), which
    /// reads as a zero-ideal editor - VSplitView/VStack then hand the
    /// pane's spare space to the other rows, which inflate into blank
    /// bands and squeeze the editor out.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: EditorRootView,
        context: Context
    ) -> CGSize? {
        // fillsContainer promises "accept whatever the stack proposes".
        // A nil proposal dimension (unbounded axis) must NOT fall back to
        // fittingSize: the constraint-based root reads near-zero there,
        // collapsing the editor to invisibility while keyboard focus and
        // the IME keep working on the zero-sized view. Fall back to the
        // view's current frame instead - the last real layout.
        let fitting = nsView.frame.size
        return CGSize(
            width: proposal.width ?? max(fitting.width, 400),
            height: proposal.height ?? max(fitting.height, 200))
    }
    func makeNSView(context: Context) -> EditorRootView {
        let coordinator = context.coordinator

        let textView = EditorTextView()
        textView.focusRingType = .none
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = EditorTheme.codeBackgroundNS
        textView.textColor = EditorTheme.textPrimaryNS
        textView.insertionPointColor =
            EditorTheme.insertionPointColorNS ?? NSColor(EditorTheme.accent)
        if let selectionBackground = EditorTheme.selectionBackgroundNS {
            var attrs = textView.selectedTextAttributes
            attrs[.backgroundColor] = selectionBackground
            textView.selectedTextAttributes = attrs
        }
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        // Flush fragment rects: the band/selection alignment (see the
        // textInset doc) and the placeholder's 6pt-only text origin.
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(
            width: Editor.textInset.width,
            height: Editor.textInset.height + editorPadding.top)
        textView.typingAttributes = [.font: coordinator.textFont, .foregroundColor: EditorTheme.textPrimaryNS]
        textView.delegate = coordinator
        textView.editorCoordinator = coordinator
        textView.textStorage?.delegate = coordinator

        let scrollView = EditorScrollView()
        // Own clip view, installed BEFORE the document view (swapping the
        // content view after the document is installed orphans the text
        // view and blanks the editor). AppKit's NSClipView overrides
        // `resetCursorRects`; an empty override keeps the text view as the
        // ONLY cursor-rect source, so its exclusion of the floating bars
        // cannot be re-stamped from below.
        scrollView.contentView = EditorClipView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.onLayout = { [weak coordinator, weak textView] in
            // Paint invalidation only. Nothing here may mutate layout
            // (constraints, frames): this runs inside AppKit's layout pass,
            // and rescheduling layout from within it can starve the hosting
            // view's layer commits - the sibling SwiftUI rows around the
            // editor would blank out while AppKit-drawn content keeps
            // painting.
            coordinator?.reportContentHeight(textView)
            coordinator?.redrawGutter()
            coordinator?.applyScrollBeyond(textView)
            coordinator?.refreshWrapReserve(textView)
        }

        let root = EditorRootView(
            textView: textView,
            scrollView: scrollView,
            showsGutter: showsLineNumbers && lineNumbersMode != .off,
            showsRuler: showsOverviewRuler)
        coordinator.rootView = root
        if let ruler = root.rulerView {
            ruler.textView = textView
            ruler.coordinator = coordinator
            ruler.observeScroll(of: scrollView)
            ruler.showsBorder = overviewRulerBorder
            ruler.hidesCursor = hideCursorInOverviewRuler
        }
        guard let gutter = root.gutterView else { return root }
        gutter.textView = textView
        gutter.showsSeparator = showsGutterSeparator
        gutter.observeScroll(of: scrollView)
        gutter.highlighter = coordinator.highlighter
        gutter.coordinator = coordinator
        gutter.font = font.nsFont

        // Initial fill through the standard pipeline: setting the storage
        // fires the text-storage delegate, which parses and paints.
        coordinator.replaceAll(text, in: textView)
        // Detection runs after the fill (the document decides), then the
        // tab stops and wrap follow the possibly-overridden config.
        coordinator.detectIndentationIfNeeded(text)
        coordinator.applyTabStops(to: textView)
        coordinator.applyWordWrap(wordWrap, to: textView)
        return root
    }

    func updateNSView(_ root: EditorRootView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.suggest?.candidatesChanged(suggestItems)
        coordinator.signatureHelp.setProvider(signatureProvider)
        guard let textView = root.textView else { return }
        textView.isEditable = isEditable

        // Gutter/ruler visibility follows the host at runtime (Monaco's
        // `updateOptions()`): the root flips hidden + constraint widths,
        // the placeholder clears the strip when the gutter is gone.
        let effectiveShowsGutter = showsLineNumbers && lineNumbersMode != .off
        root.setShowsGutter(effectiveShowsGutter)
        root.setShowsRuler(showsOverviewRuler)
        // Gutter width lives in the SwiftUI update pass: idempotent, runs
        // before layout, never re-enters layout from inside it.
        if let gutter = root.gutterView {
            gutter.font = font.nsFont
            gutter.showsSeparator = showsGutterSeparator
            if effectiveShowsGutter {
                let width = gutter.requiredWidth()
                root.setGutterWidth(width)
                gutter.needsDisplay = true
                onGutterWidthChange?(width)
            } else {
                onGutterWidthChange?(0)
            }
        }

        if textView.string != text {
            // IME composition in flight: the storage holds the live marked
            // string, which the stale binding hasn't seen yet. Replacing
            // now (setAttributedString outside the IME's edit protocol)
            // invalidates the marked range and corrupts AppKit's attribute
            // fix-up state - the next draw throws NSRangeException deep in
            // ensureAttributesAreFixedInRange. The binding catches up
            // naturally: the commit fires textDidChange, the next update
            // sees equal strings, and only genuine external changes
            // (host switched content) still reach replaceAll.
            guard !textView.hasMarkedText() else { return }
            // Just-committed CJK protection: the host may mutate its
            // binding in the same frame (onChange handlers like a shebang
            // sync) from a pre-commit snapshot; replaceAll with that
            // stale value wipes the committed text. The storage is the
            // truth right after a commit - give the host a beat to catch
            // up (its own textDidChange already synced the committed
            // string into the binding, so only genuinely stale writes
            // race this window).
            if let last = coordinator.lastCommitTime,
                Date().timeIntervalSince(last) < 0.25
            {
                return
            }
            // Editor-owned input (typing, paste, IME commit) already
            // synced the binding via textDidChange, so lastSyncText ==
            // textView.string and replaceAll would clobber fresh input with
            // a stale value. Only genuine external changes (host switched
            // content) reach here - lastSyncText differs from the live
            // storage in that case.
            if coordinator.lastSyncText == textView.string {
                return
            }
            coordinator.replaceAll(text, in: textView)
        } else if coordinator.lastRestyleKey != restyleKey || coordinator.lastSyntax != syntax {
            // Annotation scope changed (an environment switch on the host
            // side) or the syntax profile changed: re-style from scratch.
            // Rare - the full static pass is fine here.
            coordinator.lastRestyleKey = restyleKey
            coordinator.lastSyntax = syntax
            coordinator.highlighter.setProfile(syntax)
            coordinator.refreshStyling(in: textView)
        }

        // Indentation config follows the host until detection has spoken;
        // tab stops (and the host's line-height multiplier, in the same
        // paragraph style) re-apply when the width changed.
        if !coordinator.didDetectIndentation {
            let config = EditorCoordinator.IndentConfiguration(
                tabSize: max(tabSize, 1), insertSpaces: insertSpaces)
            if config != coordinator.indent {
                coordinator.indent = config
                coordinator.applyTabStops(to: textView)
                textView.needsDisplay = true
            }
        }
        coordinator.applyTabStops(to: textView)
        coordinator.applyWordWrap(wordWrap, to: textView)

        // Vertical padding: part of the container
        // inset. Idempotent; triggers one height re-report when it moves.
        let insetHeight = Editor.textInset.height + editorPadding.top
        if abs(textView.textContainerInset.height - insetHeight) > 0.5 {
            textView.textContainerInset = NSSize(
                width: Editor.textInset.width, height: insetHeight)
            coordinator.reportContentHeight(textView)
        }

        // The floating bars sit over the text view. Hand the text view
        // their rect so it drops its I-beam cursor claim there; otherwise
        // AppKit's cursor rectangles (resolved after SwiftUI sets a
        // cursor) paint the insertion cursor over the whole bar and its
        // buttons never show the pointing hand.
        //
        // The rect is COMPUTED here, not measured in SwiftUI: the bars'
        // layouts are all fixed widths anchored top-trailing, so the
        // coordinator can derive it from the root's bounds and the shared
        // card metrics - no geometry-callback round-trip to break. It is
        // computed in the ROOT's coordinates and then CONVERTED into the
        // text view's (flipped, scroll-dependent) system - assigning root
        // coordinates directly would land the exclusion at the BOTTOM of
        // the flipped text view, leaving the bar fully I-beam'd.
        coordinator.refreshCursorExclusion()
        coordinator.syncLinks(in: textView)
        coordinator.applyScrollBeyond(textView)

        // Overview-ruler switches follow the host (idempotent).
        if let ruler = root.rulerView {
            if ruler.showsBorder != overviewRulerBorder
                || ruler.hidesCursor != hideCursorInOverviewRuler
            {
                ruler.showsBorder = overviewRulerBorder
                ruler.hidesCursor = hideCursorInOverviewRuler
                ruler.needsDisplay = true
            }
        }

        // Find/action/goto pipeline (missing from the original: buttons
        // and go-to-line actions set state but never executed). Actions are
        // processed synchronously for immediate feedback; SwiftUI-state
        // clears are deferred (synchronous writes inside update transactions
        // are silently dropped) and tracked locally so re-renders don't
        // re-execute.
        if let action = findAction, action != coordinator.lastProcessedFindAction {
            coordinator.performFindAction(action, in: textView)
            coordinator.lastProcessedFindAction = action
            DispatchQueue.main.async { onFindActionHandled?() }
        }
        if let line = gotoLine,
            line != coordinator.lastProcessedGotoLine
                || gotoColumn != coordinator.lastProcessedGotoColumn
        {
            coordinator.goToLine(line, column: gotoColumn, in: textView)
            coordinator.lastProcessedGotoLine = line
            coordinator.lastProcessedGotoColumn = gotoColumn
            DispatchQueue.main.async { onGoToLineHandled?() }
        }
        if let pending = outlinePendingRange, pending != coordinator.lastProcessedOutlineRange {
            coordinator.goToOutlineRange(pending, in: textView)
            coordinator.lastProcessedOutlineRange = pending
            DispatchQueue.main.async { onOutlinePendingHandled?() }
        }
        coordinator.syncFindState(find, in: textView)
        // Host markers changed: re-run the squiggle pass (the tree's own
        // diagnostics re-render with it - the merged entry list).
        if markers != coordinator.lastHostMarkers {
            coordinator.lastHostMarkers = markers
            coordinator.hostMarkers = markers
            coordinator.refreshDiagnostics(in: textView)
        }
    }
    static func dismantleNSView(_ root: EditorRootView, coordinator: EditorCoordinator) {
        coordinator.suggest?.hide()
        coordinator.signatureHelp.hide()
    }
}

/// Root container laying the gutter left of the scroll view and the
/// overview ruler right of it, with explicit constraints (no stack view:
/// the gutter width is a live constraint).
final class EditorRootView: NSView {
    private(set) weak var textView: NSTextView?
    private(set) weak var gutterView: EditorGutterView?
    private(set) weak var rulerView: EditorOverviewRulerView?
    private let gutterWidthConstraint: NSLayoutConstraint
    private let rulerWidthConstraint: NSLayoutConstraint

    init(textView: NSTextView, scrollView: NSScrollView, showsGutter: Bool, showsRuler: Bool) {
        self.textView = textView
        let gutter = EditorGutterView(frame: .zero)
        gutterView = gutter
        let ruler = EditorOverviewRulerView(frame: .zero)
        rulerView = ruler
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        gutter.translatesAutoresizingMaskIntoConstraints = false
        ruler.translatesAutoresizingMaskIntoConstraints = false
        gutterWidthConstraint = gutter.widthAnchor.constraint(equalToConstant: 30)
        rulerWidthConstraint = ruler.widthAnchor.constraint(equalToConstant: EditorOverviewRulerView.width)
        super.init(frame: .zero)
        addSubview(gutter)
        addSubview(scrollView)
        addSubview(ruler)
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutterWidthConstraint,
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ruler.trailingAnchor.constraint(equalTo: trailingAnchor),
            ruler.topAnchor.constraint(equalTo: topAnchor),
            ruler.bottomAnchor.constraint(equalTo: bottomAnchor),
            rulerWidthConstraint,
        ])
        gutter.isHidden = !showsGutter
        ruler.isHidden = !showsRuler
        if !showsRuler {
            // A hidden view still participates in constraints; collapse the
            // strip so the text area reclaims its width.
            rulerWidthConstraint.constant = 0
        }
    }

    func setGutterWidth(_ width: CGFloat) {
        guard let gutterView, !gutterView.isHidden else { return }
        gutterWidthConstraint.constant = width
    }

    /// Runtime gutter visibility (Monaco `updateOptions()` parity): flips
    /// the strip without rebuilding the view hierarchy. Hidden keeps the
    /// historic 30pt layout reservation; visible width flows through
    /// `setGutterWidth` on the next update pass.
    func setShowsGutter(_ visible: Bool) {
        guard let gutterView, gutterView.isHidden != !visible else { return }
        gutterView.isHidden = !visible
        if !visible {
            gutterWidthConstraint.constant = 30
        }
    }

    /// Runtime ruler visibility: hidden collapses the 14pt strip so the
    /// text reclaims the width, like the init path.
    func setShowsRuler(_ visible: Bool) {
        guard let rulerView, rulerView.isHidden != !visible else { return }
        rulerView.isHidden = !visible
        rulerWidthConstraint.constant = visible ? EditorOverviewRulerView.width : 0
    }

    required init?(coder: NSCoder) {
        fatalError("EditorRootView is created in code only")
    }
}

/// NSScrollView that reports layout passes, so the auto-grow editor tracks
/// content-height changes caused by width changes (window resizes) and the
/// gutter redraws after rewraps.
final class EditorScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    /// ⌃+wheel zooms the editor's font scale (Monaco
    /// `mouseWheelZoom`); plain wheel scrolls as usual.
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control]) == .control,
            let textView = (documentView as? EditorTextView),
            textView.window?.firstResponder === textView,
            let coordinator = textView.editorCoordinator
        {
            let delta = event.scrollingDeltaY
            if delta > 0.01 {
                coordinator.zoom(in: textView)
            } else if delta < -0.01 {
                coordinator.zoomOut(in: textView)
            }
            return
        }
        super.scrollWheel(with: event)
    }
}

/// The editor's clip view. AppKit's NSClipView overrides
/// `resetCursorRects`; an empty override keeps the text view as the only
/// cursor-rect source so its exclusion of the floating bars stands (the
/// stack's `documentCursor` is nil, so nothing else is lost). Must be
/// installed BEFORE the document view.
final class EditorClipView: NSClipView {
    override func resetCursorRects() {}
}

/// NSTextView with the editor's key surfaces: ⌥⇧F formatting (intercepted
/// in `keyDown` - AppKit routes only Command-carrying events through
/// `performKeyEquivalent`, so an Option+Shift press would sail past as the
/// composed character), ⌘/ comment toggling, and bracket/quote smart
/// insertion in `insertText`.
final class EditorTextView: NSTextView, NSViewToolTipOwner {
    weak var editorCoordinator: EditorCoordinator?
    /// The current-line band's last drawn rect (for targeted invalidation).
    private var lineBandRect: NSRect = .zero
    /// The registered tooltip rect's tag + the bounds it covers (re-registered
    /// when the view grows, so hovers work over newly revealed content).
    private var tooltipTag: NSView.ToolTipTag?
    private var tooltipBounds: NSRect = .zero
    /// Font stand-in when the view's font is momentarily nil (draw pass
    /// before the first attribute application).
    static let fallbackFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// Region of this view the editor must NOT claim an I-beam cursor
    /// over: the floating find / go-to bars, which hover above the text
    /// view. Coordinates are this view's.
    ///
    /// AppKit resolves the cursor from real cursor rectangles and does so
    /// AFTER SwiftUI has applied a `.pointerStyle`, so this text view's
    /// full-bounds I-beam covered the bars too and every one of their
    /// buttons hovered as the insertion cursor instead of the pointing
    /// hand. Dropping the claim underneath them lets the overlay's own
    /// pointer styles win; the bars' text fields keep their own I-beam
    /// because they install their own cursor rectangles.
    var cursorExclusionRect: NSRect = .zero {
        didSet {
            guard cursorExclusionRect != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    /// The I-beam everywhere except `cursorExclusionRect`.
    override func resetCursorRects() {
        guard !cursorExclusionRect.isEmpty, !bounds.isEmpty else {
            super.resetCursorRects()
            return
        }
        let rects = Self.rects(within: bounds, excluding: cursorExclusionRect)
        for rect in rects {
            addCursorRect(rect, cursor: .iBeam)
        }
    }

    /// Same exclusion for the mouse-moved path: NSTextView manages the
    /// cursor from `mouseMoved` too (its tracking areas deliver those
    /// events across the text view's whole bounds, and the floating bars -
    /// layer content in the hosting view - never occlude them at the
    /// AppKit level). Without this decline, every mouse move over a bar
    /// re-stamps the I-beam right after SwiftUI's pointer style has set
    /// the pointing hand - the "hand flashes, then I-beam" flicker.
    override func mouseMoved(with event: NSEvent) {
        if isInCursorExclusion(event.locationInWindow) {
            nextResponder?.mouseMoved(with: event)
            return
        }
        super.mouseMoved(with: event)
    }

    /// Tracking-area entries: same decline as `mouseMoved` (an enter at a
    /// point inside a bar must not stamp the I-beam either).
    override func mouseEntered(with event: NSEvent) {
        if isInCursorExclusion(event.locationInWindow) {
            nextResponder?.mouseEntered(with: event)
            return
        }
        super.mouseEntered(with: event)
    }

    /// Same exclusion for the MODERN cursor path: cursor-update events.
    /// NSTextView carries a tracking area across its whole bounds, and the
    /// floating bars are not AppKit views (they are layer content in the
    /// hosting view), so nothing occludes that area at the AppKit level -
    /// the text view's `cursorUpdate` keeps stamping the I-beam over the
    /// bars no matter what `resetCursorRects` says. Declining the event in
    /// the excluded region (forwarding up the responder chain, where the
    /// hosting view's SwiftUI pointer machinery lives) lets the bars'
    /// pointing-hand styles stand.
    override func cursorUpdate(with event: NSEvent) {
        if isInCursorExclusion(event.locationInWindow) {
            nextResponder?.cursorUpdate(with: event)
            return
        }
        super.cursorUpdate(with: event)
    }

    /// Whether `windowPoint` falls in `cursorExclusionRect`.
    private func isInCursorExclusion(_ windowPoint: NSPoint) -> Bool {
        guard !cursorExclusionRect.isEmpty else { return false }
        return cursorExclusionRect.contains(convert(windowPoint, from: nil))
    }

    /// `area` minus `hole`, as up to four disjoint rectangles.
    private static func rects(within area: NSRect, excluding hole: NSRect) -> [NSRect] {
        let clipped = hole.intersection(area)
        guard !clipped.isNull, !clipped.isEmpty else { return [area] }
        var rects: [NSRect] = []
        if clipped.minY > area.minY {
            rects.append(
                NSRect(x: area.minX, y: area.minY, width: area.width, height: clipped.minY - area.minY))
        }
        if clipped.maxY < area.maxY {
            rects.append(
                NSRect(x: area.minX, y: clipped.maxY, width: area.width, height: area.maxY - clipped.maxY))
        }
        if clipped.minX > area.minX {
            rects.append(
                NSRect(x: area.minX, y: clipped.minY, width: clipped.minX - area.minX, height: clipped.height))
        }
        if clipped.maxX < area.maxX {
            rects.append(
                NSRect(x: clipped.maxX, y: clipped.minY, width: area.maxX - clipped.maxX, height: clipped.height))
        }
        return rects
    }

    /// Selection boundary: clamps out-of-bounds ranges against the LIVE
    /// storage length before the layout machinery sees them. An
    /// out-of-bounds selection throws NSRangeException deep inside AppKit's
    /// caret/scroll computation - and the input system SWALLOWS that
    /// exception, leaving the text system poisoned (storage edited,
    /// layout/selection fixup unwound), so every later edit crashes.
    ///
    /// Deliberately minimal-intrusion: IME composition (`stillSelecting`,
    /// marked text) legally uses transient coordinates and is passed
    /// through untouched; in-bounds selections are handed to super as the
    /// ORIGINAL objects (no re-encoding); only genuinely out-of-bounds
    /// final selections get clamped, and the clamp logs once per burst so
    /// a repeat offender is visible in the log.
    override func setSelectedRanges(
        _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool
    ) {
        // Mouse in the glyph-less region under the last content line: the
        // empty trailing line the gutter numbers (TextKit lays out no
        // fragment for it), plus the space below. AppKit installs the
        // caret on the final newline through this setter - the click path
        // never consults `selectionRange(forProposedRange:)`, so the snap
        // must live here. Dragging (`stillSelecting`) is remapped too, so
        // the head tracks the document end through the whole drag; IME
        // composition and reentrant fixups pass through untouched.
        let effective = mouseExtendedRanges(ranges) ?? ranges
        guard !stillSelecting, !hasMarkedText(), !isFixingSelection else {
            super.setSelectedRanges(effective, affinity: affinity, stillSelecting: stillSelecting)
            return
        }
        // Smooth-caret glide captures the pre-change rect; the post-change
        // rect is derived after the setter lands below. Skipped entirely
        // when smoothing is off (the historic default).
        let preCaretRect =
            editorCoordinator?.parent.cursorSmoothCaretAnimation != .off
            ? caretDrawRect() : nil
        isFixingSelection = true
        defer { isFixingSelection = false }
        let length = (string as NSString).length
        var clampedAny = false
        let fixed = effective.map { value -> NSValue in
            let range = value.rangeValue
            // NSNotFound ("no selection") parks the caret at the end.
            let location =
                range.location == NSNotFound
                ? length : min(max(range.location, 0), length)
            let upperBound =
                range.location == NSNotFound
                ? length : min(max(NSMaxRange(range), location), length)
            if location == range.location, upperBound == NSMaxRange(range) {
                return value
            }
            clampedAny = true
            return NSValue(range: NSRange(location: location, length: upperBound - location))
        }
        if clampedAny {
            EditorSelectionClampLog.log(length: length, ranges: effective)
            super.setSelectedRanges(fixed, affinity: affinity, stillSelecting: stillSelecting)
        } else {
            super.setSelectedRanges(effective, affinity: affinity, stillSelecting: stillSelecting)
        }
        if preCaretRect != nil {
            maybeStartCaretAnimation(from: preCaretRect, to: caretDrawRect())
        }
    }

    /// Reentrancy guard: AppKit's own implementation may re-enter the
    /// public setter during fixups; the inner call must pass through
    /// un-clamped (its ranges are already in bounds by construction).
    private var isFixingSelection = false

    /// Clicks in the blank region under the laid-out text - the empty
    /// last line the gutter numbers, plus the space beneath it - hit no
    /// glyph: TextKit lays out no fragment for the line after a trailing
    /// newline, and the nearest-glyph fallback parks every such click on
    /// the final newline (the end of the last content line), so the
    /// caret visibly bounces back and the last line can never be clicked
    /// into. Code editors map that region to the document end instead;
    /// snap the caret/head there before the stock machinery installs its
    /// range. (The click path installs through `setSelectedRanges`
    /// instead, which carries the same snap - this override covers the
    /// proposal-based paths.) Keyboard and programmatic selections keep
    /// the stock mapping - the snap only applies while a mouse event is
    /// in flight.
    override func selectionRange(
        forProposedRange proposed: NSRange, granularity: NSSelectionGranularity
    ) -> NSRange {
        let mouseTypes: [NSEvent.EventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        let belowText =
            granularity == .selectByCharacter
            && !string.isEmpty
            && window?.currentEvent.map { event in
                mouseTypes.contains(event.type)
                    && isBelowLaidOutText(convert(event.locationInWindow, from: nil))
            } == true
        guard belowText else {
            return super.selectionRange(forProposedRange: proposed, granularity: granularity)
        }
        let length = (string as NSString).length
        // A caret proposal collapses to the document end; a ranged one
        // (drag, shift-click) keeps its anchor and moves the head there.
        if proposed.length == 0 {
            return NSRange(location: length, length: 0)
        }
        return NSRange(
            location: proposed.location,
            length: max(NSMaxRange(proposed), length) - proposed.location)
    }

    /// Whether `point` (view coordinates, flipped) sits at or below the
    /// bottom of the last CONTENT line fragment - i.e. inside the empty
    /// trailing line (which has no fragment of its own) or the space
    /// below it. `usedRect.maxY` can't be used as the threshold: it
    /// already includes the extra line fragment, so the phantom band
    /// would measure as laid-out - and clicks on that very band are the
    /// ones that need the snap.
    private func isBelowLaidOutText(_ point: NSPoint) -> Bool {
        guard let layoutManager, let container = textContainer, !string.isEmpty
        else { return false }
        layoutManager.ensureLayout(for: container)
        // The extra line fragment sits directly under the last content
        // fragment - its top IS the content bottom. (Enumerating line
        // fragments is the alternative, but the extra fragment already
        // encodes exactly this edge.)
        guard layoutManager.extraLineFragmentTextContainer != nil else { return false }
        return point.y >= textContainerOrigin.y + layoutManager.extraLineFragmentRect.minY
    }

    /// If the event in flight is a mouse click/drag over the glyph-less
    /// region under the last content line, returns `ranges` with the
    /// caret moved to the document end and any range whose head parks on
    /// the final newline extended through it; nil otherwise (stock
    /// mapping applies - keyboard and programmatic selections included).
    private func mouseExtendedRanges(_ ranges: [NSValue]) -> [NSValue]? {
        guard !isFixingSelection, !hasMarkedText(), !string.isEmpty,
            let event = window?.currentEvent,
            [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type),
            isBelowLaidOutText(convert(event.locationInWindow, from: nil))
        else { return nil }
        let length = (string as NSString).length
        return ranges.map { value -> NSValue in
            let range = value.rangeValue
            guard range.location != NSNotFound else { return value }
            if range.length == 0 {
                return range.location == length
                    ? value : NSValue(range: NSRange(location: length, length: 0))
            }
            guard NSMaxRange(range) == length - 1 else { return value }
            return NSValue(range: NSRange(location: range.location, length: length - range.location))
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let isFormatKey =
            modifiers == [.option, .shift]
            && (event.keyCode == 0x03 || event.charactersIgnoringModifiers?.lowercased() == "f")
        if isFormatKey, window?.firstResponder === self, let editorCoordinator {
            if editorCoordinator.applyFormatSelection(self) { return }
            if editorCoordinator.applyFormat(self) { return }
        }
        // F8 / Shift+F8: next/previous diagnostic. Selection-only, so it
        // works on read-only editors too (Monaco `gotoNext/PreviousDiagnostic`).
        if event.keyCode == 100, window?.firstResponder === self, let editorCoordinator,
            modifiers == [] || modifiers == [.shift]
        {
            editorCoordinator.goToDiagnostic(in: self, up: modifiers.contains(.shift))
            return
        }
        // F12: go to definition (Monaco `gotoDefinition`). Selection-only:
        // works on read-only editors and without a provider as a no-op.
        if event.keyCode == 111, window?.firstResponder === self, let editorCoordinator,
            modifiers == []
        {
            editorCoordinator.goToDefinition(in: self)
            return
        }
        // ⌃⇧O: document outline (Monaco `outline`). Selection-only.
        if modifiers == [.control, .shift], event.keyCode == 31,
            window?.firstResponder === self, let editorCoordinator
        {
            editorCoordinator.requestDocumentSymbols(in: self)
            return
        }
        // ⌃⇧Space: signature help on demand (Monaco `signatureHelp`).
        if modifiers == [.control, .shift], event.keyCode == 49,
            window?.firstResponder === self, let editorCoordinator
        {
            editorCoordinator.signatureHelp.showExplicitly(in: self)
            return
        }
        // ⌃T: transpose characters (Monaco `transposeChars`). Editing-only.
        if modifiers == [.control], event.keyCode == 17,
            window?.firstResponder === self, let editorCoordinator, isEditable
        {
            editorCoordinator.transposeCharacters(in: self)
            return
        }
        // ⌥Z: toggle word wrap. Selection-only: works read-only.
        if modifiers == [.option], event.keyCode == 6,
            window?.firstResponder === self, let editorCoordinator
        {
            editorCoordinator.toggleWordWrap(in: self)
            return
        }
        // ⌃= / ⌃⌥- / ⌃0: zoom the editor-local font scale (Monaco `editorZoom`).
        // Zoom-out moved off ⌃- when navigation took it (⌃- = Go Back,
        // VS Code). Ctrl (not ⌘) so app-level window magnification keeps ⌘+/-.
        // Selection-only: zooms read-only editors too.
        if window?.firstResponder === self, let editorCoordinator {
            let chars = event.charactersIgnoringModifiers?.lowercased()
            if modifiers == [.control] {
                if event.keyCode == 24 || chars == "=" || chars == "+" {
                    editorCoordinator.zoom(in: self)
                    return
                }
                if event.keyCode == 29 || chars == "0" {
                    editorCoordinator.zoomReset(in: self)
                    return
                }
            }
            if modifiers == [.control, .option], event.keyCode == 27 || chars == "-" {
                editorCoordinator.zoomOut(in: self)
                return
            }
        }
        // ⌥⇧↑ / ⌥⇧↓: copy the selection's lines above/below (Monaco
        // copy-lines). Editing-only; plain ⌃⌘↑/↓ stays move.
        if modifiers == [.option, .shift], window?.firstResponder === self, let editorCoordinator,
            isEditable
        {
            if event.keyCode == 126 {
                editorCoordinator.copyLines(in: self, up: true)
                return
            }
            if event.keyCode == 125 {
                editorCoordinator.copyLines(in: self, up: false)
                return
            }
        }
        // Esc: completion first, signature next, then a visible find bar.
        if event.keyCode == 53, window?.firstResponder === self, let editorCoordinator,
            editorCoordinator.suggest?.isVisible != true
        {
            if editorCoordinator.signatureHelp.handleCommand(#selector(NSResponder.cancelOperation(_:))) {
                return
            }
            if editorCoordinator.parent.find.visible {
                editorCoordinator.closeFind(in: self)
                return
            }
        }
        // ⌘⌫: delete to the logical line's start (a selection keeps the
        // platform's delete-selection behavior).
        if modifiers == [.command], event.keyCode == 51,
            window?.firstResponder === self, selectedRange().length == 0,
            let editorCoordinator
        {
            editorCoordinator.deleteToLogicalLineStart(in: self)
            return
        }
        // ⌃K: delete to the line's end (Monaco `deleteAllRight`).
        if modifiers == [.control], event.keyCode == 40,
            window?.firstResponder === self, isEditable, let editorCoordinator
        {
            editorCoordinator.deleteToLineEnd(in: self)
            return
        }
        // Right arrow: jump past a closing bracket/quote when the caret
        // sits right before it, so the paired character does not trap the
        // caret between the pair.
        if event.keyCode == 124, selectedRange().length == 0, !string.isEmpty {
            let caret = selectedRange().location
            let text = string as NSString
            if caret < text.length {
                let char = codeEditorChar(text, caret)
                if ")]}".contains(char ?? " ") || char == "\"" || char == "'" || char == "`" {
                    let newLocation = min(caret + 1, text.length)
                    setSelectedRange(NSRange(location: newLocation, length: 0))
                    scrollRangeToVisible(NSRange(location: newLocation, length: 0))
                    return
                }
            }
        }
        isTypingKeystroke = true
        defer { isTypingKeystroke = false }
        super.keyDown(with: event)
    }

    // MARK: Read-only edit interception

    // Deletes and cuts have their own responders; every other edit path
    // (typing, paste, IME commit, drops) funnels through insertText.
    // Each edit attempt on a read-only editor surfaces the host's notice
    // instead of dying silently.
    /// ⌥⎋ / F5: the host's explicit completion trigger (Monaco
    /// `triggerSuggest`). The engine decides whether a popup opens;
    /// without one (or a read-only editor) the stock AppKit word
    /// completion stands in.
    override func complete(_ sender: Any?) {
        if isEditable, let suggest = editorCoordinator?.suggest,
            suggest.triggerSuggest(in: self)
        {
            return
        }
        super.complete(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        guard isEditable else {
            editorCoordinator?.notifyReadOnlyAttempt()
            return
        }
        if let coordinator = editorCoordinator, coordinator.deleteAutoPair(in: self) {
            return
        }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        guard isEditable else {
            editorCoordinator?.notifyReadOnlyAttempt()
            return
        }
        super.deleteForward(sender)
    }

    override func cut(_ sender: Any?) {
        guard isEditable else {
            editorCoordinator?.notifyReadOnlyAttempt()
            return
        }
        if selectedRange().length == 0,
            let coordinator = editorCoordinator,
            coordinator.cutLine(in: self)
        {
            return
        }
        super.cut(sender)
    }

    /// Plain ⌘V. With `formatOnPaste` the pasted string goes through the
    /// format handler when it parses; anything else (off by default,
    /// no handler, unparseable, IME composition) is the stock paste.
    override func paste(_ sender: Any?) {
        guard isEditable else {
            editorCoordinator?.notifyReadOnlyAttempt()
            return
        }
        guard let coordinator = editorCoordinator, coordinator.parent.formatOnPaste,
            coordinator.parent.formatHandler != nil, !hasMarkedText(),
            let pasted = NSPasteboard.general.string(forType: .string), !pasted.isEmpty
        else {
            super.paste(sender)
            return
        }
        if coordinator.formatPastedString(pasted, in: self) { return }
        super.paste(sender)
    }

    /// Text-drop acceptance. The
    /// TextKit-1 drag-initiation hook (`dragSelectionWithEvent`) no
    /// longer exists on modern SDKs, so the off switch works from the
    /// drop side: text drops (including selection-move drags that land
    /// here) are declined when disabled.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard editorCoordinator?.parent.dragAndDropEnabled != false else { return false }
        return super.performDragOperation(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard window?.firstResponder === self, let coordinator = editorCoordinator else {
            return super.performKeyEquivalent(with: event)
        }
        if modifiers == [.command], event.charactersIgnoringModifiers == "/" {
            if coordinator.toggleComment(self) { return true }
            return super.performKeyEquivalent(with: event)
        }
        // ⇧⌥A: toggle block comment (Monaco blockComment). Editing-only;
        // without a block pair it falls through.
        if modifiers == [.shift, .option],
            event.charactersIgnoringModifiers?.lowercased() == "a"
        {
            if coordinator.toggleExplicitBlockComment(self) { return true }
            return super.performKeyEquivalent(with: event)
        }
        // Smart select (⌃⇧⌘→ / ⌃⇧⌘←). Selection-only, so it
        // works on read-only editors too - hence ahead of the editable
        // guard below.
        if modifiers == [.control, .shift, .command], event.keyCode == 124 {
            coordinator.expandSmartSelection(in: self)
            return true
        }
        if modifiers == [.control, .shift, .command], event.keyCode == 123 {
            coordinator.shrinkSmartSelection(in: self)
            return true
        }
        // ⌘F12 / ⌥F12: go to definition (declaration alias). Selection-only,
        // ahead of the editable guard like smart select.
        let isDefinitionKey = modifiers == [.command] || modifiers == [.command, .option]
        if isDefinitionKey, event.keyCode == 111 {
            coordinator.goToDefinition(in: self)
            return true
        }
        // ⌃⌘D / ⌃⌘⇧D: select the next/previous occurrence of the
        // word/selection (Monaco `addSelectionToNext/PreviousMatch`).
        // Selection-only single-caret fallback: multi-cursor is a
        // deliberate non-goal, so this moves the selection instead of
        // adding a second one. ⌘D keeps duplicate-lines (historic).
        if modifiers == [.control, .command],
            event.charactersIgnoringModifiers?.lowercased() == "d"
        {
            coordinator.selectNextMatch(in: self)
            return true
        }
        if modifiers == [.control, .command, .shift],
            event.charactersIgnoringModifiers?.lowercased() == "d"
        {
            coordinator.selectPreviousMatch(in: self)
            return true
        }
        // ⌃- / ⌃⇧-: navigation back/forward through programmatic jumps
        // (Monaco navigateBack/navigateForward). Selection-only.
        if event.keyCode == 27 || event.keyCode == 78,
            modifiers == [.control] || modifiers == [.control, .shift]
        {
            if modifiers == [.control] {
                coordinator.navigateBack(in: self)
            } else {
                coordinator.navigateForward(in: self)
            }
            return true
        }
        // ⌘L: select the current line (Monaco expandLineSelection);
        // repeat presses grow the selection one line down.
        if modifiers == [.command], event.charactersIgnoringModifiers == "l" {
            coordinator.selectLine(in: self)
            return true
        }
        // ⌥⌘G: toggle find-in-selection, capturing the live selection.
        // Navigation-only: works on read-only editors like the find keys.
        if modifiers == [.command, .option],
            event.charactersIgnoringModifiers?.lowercased() == "g"
        {
            coordinator.performFindAction(.toggleInSelection, in: self)
            return true
        }
        guard isEditable || Self.isNavigationEquivalent(event: event, modifiers: modifiers) else {
            return super.performKeyEquivalent(with: event)
        }
        if modifiers == [.command], event.charactersIgnoringModifiers == "f" {
            coordinator.requestFind(replaceMode: false, in: self)
            return true
        }
        if modifiers == [.command, .option], event.charactersIgnoringModifiers == "f" {
            coordinator.requestFind(replaceMode: true, in: self)
            return true
        }
        if modifiers == [.command], event.charactersIgnoringModifiers == "g" {
            coordinator.performFindAction(.next, in: self)
            return true
        }
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers == "g" {
            coordinator.performFindAction(.previous, in: self)
            return true
        }
        // ⌘⇧\: jump to the matching bracket (Monaco `jumpToBracket`).
        if modifiers == [.command, .shift], event.keyCode == 42 {
            coordinator.jumpToMatchingBracket(in: self)
            return true
        }
        // ⌘⌥Enter: replace the current match (Monaco's replace-one key).
        if modifiers == [.command, .option], event.keyCode == 36,
            coordinator.parent.find.visible
        {
            coordinator.performFindAction(.replaceCurrent, in: self)
            return true
        }
        // ⌘⌥⇧Enter: replace all (Monaco's replace-all key).
        if modifiers == [.command, .option, .shift], event.keyCode == 36,
            coordinator.parent.find.visible
        {
            coordinator.performFindAction(.replaceAll, in: self)
            return true
        }
        // ⌘Enter / ⇧⌘Enter: insert an empty line below/above the
        // selection's lines (Monaco insertLineAfter/insertLineBefore).
        if event.keyCode == 36 || event.keyCode == 76,
            modifiers == [.command] || modifiers == [.command, .shift]
        {
            coordinator.insertLine(in: self, below: modifiers == [.command])
            return true
        }
        if modifiers == [.command], event.charactersIgnoringModifiers == "d" {
            coordinator.duplicateLines(in: self)
            return true
        }
        if modifiers == [.command], event.charactersIgnoringModifiers == "]" {
            coordinator.indentSelection(self, outdent: false)
            return true
        }
        if modifiers == [.command], event.charactersIgnoringModifiers == "[" {
            coordinator.indentSelection(self, outdent: true)
            return true
        }
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers == "k" {
            coordinator.deleteLines(in: self)
            return true
        }
        if modifiers == [.command, .control], event.keyCode == 126 {
            coordinator.moveLines(in: self, up: true)
            return true
        }
        if modifiers == [.command, .control], event.keyCode == 125 {
            coordinator.moveLines(in: self, up: false)
            return true
        }
        if modifiers == [.command, .option], event.charactersIgnoringModifiers == "l" {
            coordinator.requestLinePanel(in: self)
            return true
        }
        if modifiers == [.command, .option], event.charactersIgnoringModifiers == "e" {
            coordinator.useSelectionForFind(in: self)
            return true
        }
        if modifiers == [.command, .option, .shift], event.charactersIgnoringModifiers == "v" {
            coordinator.pasteAndFormat(in: self)
            return true
        }
        // Host-registered actions: exact modifier
        // match on the key equivalent.
        for action in coordinator.parent.actions {
            guard let key = action.key,
                action.modifiers == modifiers,
                event.charactersIgnoringModifiers?.lowercased() == key.lowercased()
            else { continue }
            action.run()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Navigation equivalents (⌘F/⌘G and friends) stay live in read-only
    /// editors; editing ones do not.
    private static func isNavigationEquivalent(event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        if modifiers == [.command], ["f", "g"].contains(event.charactersIgnoringModifiers ?? "") {
            return true
        }
        if modifiers == [.command, .option], event.charactersIgnoringModifiers == "f" {
            return true
        }
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers == "g" {
            return true
        }
        if modifiers == [.control, .command], event.charactersIgnoringModifiers?.lowercased() == "d" {
            return true
        }
        if modifiers == [.control, .command, .shift], event.charactersIgnoringModifiers?.lowercased() == "d" {
            return true
        }
        let isDefinitionKey = modifiers == [.command] || modifiers == [.command, .option]
        if isDefinitionKey, event.keyCode == 111 {
            return true
        }
        return false
    }

    /// ⌘-click: go to definition (Monaco `gotoDefinition`). Other clicks
    /// keep the stock caret behavior.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command]).contains(.command),
            let coordinator = editorCoordinator,
            coordinator.parent.definitionProvider != nil,
            !hasMarkedText(),
            let layoutManager, let container = textContainer
        {
            let point = convert(event.locationInWindow, from: nil)
            let index = layoutManager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            let length = (string as NSString).length
            if index < length {
                coordinator.goToDefinition(atCharacterIndex: index, in: self)
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// ⌘C. With an empty selection (Monaco `clipboardCopyAction`) the
    /// current line goes to the pasteboard instead (with its trailing
    /// newline); a selection keeps the stock copy.
    override func copy(_ sender: Any?) {
        if selectedRange().length == 0,
            let coordinator = editorCoordinator,
            coordinator.copyLine(in: self)
        {
            return
        }
        super.copy(sender)
    }

    override func otherMouseDown(with event: NSEvent) {
        // Middle button pastes at the clicked position (X11/terminal
        // muscle memory); any other non-primary button falls through.
        guard event.type == .otherMouseDown, event.buttonNumber == 2,
            isEditable, let text = NSPasteboard(name: .findPboard).string(forType: .string),
            !text.isEmpty,
            let layoutManager, let container = textContainer
        else {
            super.otherMouseDown(with: event)
            return
        }
        let index = layoutManager.characterIndex(
            for: convert(event.locationInWindow, from: nil), in: container,
            fractionOfDistanceBetweenInsertionPoints: nil)
        let length = (string as NSString).length
        let location = min(index, length)
        setSelectedRange(NSRange(location: location, length: 0))
        insertText(text, replacementRange: NSRange(location: location, length: 0))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerTooltipRect()
        // The fill's diagnostics pass deferred until a window existed.
        if window != nil {
            editorCoordinator?.flushPendingDiagnostics(in: self)
        }
    }

    override func layout() {
        super.layout()
        registerTooltipRect()
        // The band spans to the view's right edge, so a resize changes
        // its width without moving the caret or the text.
        refreshLineBand()
    }

    /// One tooltip rect covering the view; re-registered when the bounds
    /// grow (the owner hit-tests by point, so the rect just needs to cover
    /// the area the mouse can be in).
    private func registerTooltipRect() {
        guard window != nil, bounds != tooltipBounds else { return }
        if let tooltipTag { removeToolTip(tooltipTag) }
        tooltipBounds = bounds
        tooltipTag = addToolTip(bounds, owner: self, userData: nil)
    }

    /// Hover over an error squiggle: the diagnostic with its line/column.
    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard let coordinator = editorCoordinator, let layoutManager, let textContainer else { return "" }
        let characterIndex = layoutManager.characterIndex(for: point, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        // Diagnostics win: the marker's own tooltip takes precedence over
        // any host hover on the same token.
        for entry in coordinator.diagnosticEntries
        where NSLocationInRange(characterIndex, entry.range) {
            let position = coordinator.highlighter.lineAndColumn(ofUTF16Offset: entry.range.location)
            let label = entry.severity == .error ? "" : "\(entry.severity): "
            return "\(label)\(entry.message) (line \(position.line), column \(position.column))"
        }
        // Host hover provider: consult on the range under the pointer.
        if let hoverProvider = coordinator.parent.hoverProvider, characterIndex < nsStringLength {
            let tokenRange = hoverRange(at: characterIndex)
            if let text = hoverProvider(tokenRange) { return text }
        }
        return ""
    }

    /// The word-ish range under `characterIndex` for hover purposes: expands
    /// over identifier characters ([A-Za-z0-9_-]) so hosts receive a stable
    /// token range rather than the pointer's exact offset.
    private func hoverRange(at index: Int) -> NSRange {
        let ns = string as NSString
        guard index < ns.length else { return NSRange(location: index, length: 0) }
        let identifier = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var start = index
        while start > 0 {
            let previous = ns.substring(with: NSRange(location: start - 1, length: 1))
            guard previous.rangeOfCharacter(from: identifier) != nil else { break }
            start -= 1
        }
        var end = index + 1
        while end < ns.length {
            let next = ns.substring(with: NSRange(location: end, length: 1))
            guard next.rangeOfCharacter(from: identifier) != nil else { break }
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }

    private var nsStringLength: Int { (string as NSString).length }

    /// Custom draw pass: the background and the caret line's band first,
    /// then super.draw (selection wash + glyphs), then the under-text
    /// decorations that must stay visible through the (opaque) selection
    /// wash - the indent/bracket guides and whitespace markers, drawn at
    /// low alpha over everything (they live in whitespace columns, so
    /// they never cross glyph ink) - then the remaining over-text
    /// overlays. `EditorTheme.debugDisableCustomDrawing` is the
    /// diagnostic switch that skips all of it and renders text only.
    override func draw(_ dirtyRect: NSRect) {
        if EditorTheme.debugDisableCustomDrawing {
            super.draw(dirtyRect)
            return
        }
        // Paint the background first: `drawsBackground` is false so AppKit
        // does not repaint it over the decorations. Background is skipped
        // in the debug path, where `super.draw` still paints it.
        backgroundColor.setFill()
        dirtyRect.fill()
        drawLineBand()
        super.draw(dirtyRect)
        drawIndentGuides(dirtyRect: dirtyRect)
        drawBracketGuides(dirtyRect: dirtyRect)
        drawWhitespace(dirtyRect: dirtyRect)
        drawRulers(dirtyRect: dirtyRect)
        drawControlCharacters(dirtyRect: dirtyRect)
        drawColorDecorators(dirtyRect: dirtyRect)
        drawFinalNewline()
        drawCustomCaret()
    }

    /// The band behind the caret's line.
    private func drawLineBand() {
        guard let coordinator = editorCoordinator else { return }
        switch coordinator.parent.renderLineHighlight {
        case .none, .gutter: return
        case .line, .all: break
        }
        if coordinator.parent.renderLineHighlightOnlyWhenFocus,
            window?.firstResponder !== self
        {
            return
        }
        guard !lineBandRect.isEmpty else { return }
        EditorTheme.lineHighlightBackgroundNS.setFill()
        lineBandRect.fill()
        let borderWidth = EditorTheme.lineHighlightBorderWidth
        if borderWidth > 0 {
            EditorTheme.lineHighlightBorderNS.setStroke()
            // Border-box like Monaco: the stroke lies INSIDE the band's
            // total height (the 1.5 × fontSize box includes the border).
            let border = NSBezierPath(
                rect: lineBandRect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2))
            border.lineWidth = borderWidth
            border.stroke()
        }
    }

    /// Vertical rulers.
    private func drawRulers(dirtyRect: NSRect) {
        guard let coordinator = editorCoordinator,
            !coordinator.parent.rulers.isEmpty
        else { return }
        let spaceWidth = coordinator.spaceWidth(for: font ?? Self.fallbackFont)
        // Same anchor as the text cells (`lineFragmentPadding` is zero):
        // column n's hairline sits at the LEFT EDGE of cell n - 1, so
        // `rulers: [80]` on a 4-space body lands on the first character
        // past the margin, matching editor conventions.
        let baseX = textContainerOrigin.x
        let color = EditorTheme.textPrimaryNS.withAlphaComponent(0.25)
        color.setFill()
        let top = dirtyRect.minY
        let height = dirtyRect.height
        for column in coordinator.parent.rulers where column >= 1 {
            let rulerX = baseX + CGFloat(column - 1) * spaceWidth
            NSRect(x: rulerX, y: top, width: 1, height: height).fill()
        }
    }

    /// Control characters and
    /// ambiguous unicode, drawn as faint boxes over the glyphs.
    private func drawControlCharacters(dirtyRect: NSRect) {
        guard let coordinator = editorCoordinator,
            coordinator.parent.renderControlCharacters || coordinator.parent.unicodeHighlight,
            let layoutManager, let container = textContainer, !string.isEmpty
        else { return }
        let ns = string as NSString
        let length = ns.length
        let bounding = dirtyRect.offsetBy(
            dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: bounding, in: container)
        let controlColor = NSColor(EditorTheme.error).withAlphaComponent(0.35)
        let unicodeColor = NSColor(EditorTheme.warning).withAlphaComponent(0.35)
        var index = glyphRange.location
        let end = NSMaxRange(glyphRange)
        while index < end {
            var fragmentGlyphs = NSRange()
            let lineFragment = layoutManager.lineFragmentRect(
                forGlyphAt: index, effectiveRange: &fragmentGlyphs)
            let charRange = layoutManager.characterRange(
                forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
            guard charRange.location < length else { break }
            let clampedLength = min(charRange.length, length - charRange.location)
            guard clampedLength > 0 else { break }
            let line =
                ns.substring(with: NSRange(location: charRange.location, length: clampedLength))
                as NSString
            let lineLength = max(line.length, 1)
            for position in 0..<line.length {
                let offset = charRange.location + position
                guard offset < length else { break }
                let unit = line.character(at: position)
                let isControl =
                    (unit < 0x20 && unit != 0x09 && unit != 0x0A && unit != 0x0D)
                    || unit == 0x7F || (unit >= 0x80 && unit <= 0x9F)
                let isAmbiguous =
                    unit == 0x200B || unit == 0x200E || unit == 0x200F
                    || (unit >= 0x202A && unit <= 0x202E) || (unit >= 0x2066 && unit <= 0x2069)
                    || unit == 0xFEFF
                let color: NSColor?
                if isControl, coordinator.parent.renderControlCharacters {
                    color = controlColor
                } else if isAmbiguous, coordinator.parent.unicodeHighlight {
                    color = unicodeColor
                } else {
                    color = nil
                }
                guard let color else { continue }
                let fraction = CGFloat(position) / CGFloat(lineLength)
                let box = CGRect(
                    x: lineFragment.minX + textContainerOrigin.x + fraction * lineFragment.width,
                    y: lineFragment.minY + textContainerOrigin.y,
                    width: max(lineFragment.width / CGFloat(lineLength), 3),
                    height: lineFragment.height)
                color.setFill()
                box.fill()
            }
            index = NSMaxRange(fragmentGlyphs)
        }
    }

    /// Inline color swatches before `#hex`/`rgb()`/`hsl()` tokens:
    /// a small filled box in the leading
    /// margin of the token, with a hairline border so it reads on both
    /// light and dark backgrounds.
    private func drawColorDecorators(dirtyRect: NSRect) {
        guard let coordinator = editorCoordinator, coordinator.parent.colorDecorators,
            let layoutManager, let container = textContainer, !string.isEmpty
        else { return }
        let ns = string as NSString
        let length = ns.length
        let bounding = dirtyRect.offsetBy(
            dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: bounding, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard charRange.length > 0, charRange.location < length else { return }
        let visible = NSRange(
            location: charRange.location,
            length: min(charRange.length, length - charRange.location))
        for (token, color) in Self.colorTokens(in: ns as String, range: visible).prefix(100) {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: token.location)
            var fragmentGlyphs = NSRange()
            let fragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex, effectiveRange: &fragmentGlyphs)
            let fragmentChars = layoutManager.characterRange(
                forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
            let lineLength = max(fragmentChars.length, 1)
            let fraction = CGFloat(token.location - fragmentChars.location) / CGFloat(lineLength)
            let swatch = NSRect(
                x: max(
                    fragment.minX + textContainerOrigin.x + fraction * fragment.width - 13,
                    textContainerOrigin.x),
                y: fragment.minY + textContainerOrigin.y + 3,
                width: 10,
                height: max(fragment.height - 6, 6))
            color.setFill()
            swatch.fill()
            EditorTheme.codeBackgroundNS.setStroke()
            NSBezierPath(rect: swatch.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    /// Color tokens (CSS-style subset): `#rgb/#rgba/#rrggbb/#rrggbbaa`,
    /// `rgb()/rgba()`, `hsl()/hsla()` with percentage/int forms.
    private static let colorTokenRegexes: [NSRegularExpression] = {
        let patterns = [
            "#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{4}|[0-9a-fA-F]{3})(?![0-9a-fA-F])",
            "rgba?\\(\\s*(?:\\d{1,3}%|\\d{1,3})\\s*,\\s*(?:\\d{1,3}%|\\d{1,3})\\s*,\\s*(?:\\d{1,3}%|\\d{1,3})\\s*"
                + "(?:,\\s*(?:0(?:\\.\\d+)?|1(?:\\.0+)?|(?:\\d{1,3})%)\\s*)?\\)",
            "hsla?\\(\\s*\\d{1,3}\\s*,\\s*\\d{1,3}%\\s*,\\s*\\d{1,3}%\\s*(?:,\\s*(?:0(?:\\.\\d+)?|1(?:\\.0+)?)\\s*)?\\)",
        ]
        return patterns.map { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                preconditionFailure("Invalid color token regex: \(pattern)")
            }
            return regex
        }
    }()

    private static func colorTokens(in text: String, range: NSRange) -> [(NSRange, NSColor)] {
        let ns = text as NSString
        var out: [(NSRange, NSColor)] = []
        for regex in colorTokenRegexes {
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, let color = color(from: ns.substring(with: match.range))
                else { return }
                out.append((match.range, color))
            }
        }
        return out
    }

    private static func color(from token: String) -> NSColor? {
        if token.hasPrefix("#") {
            let hex = String(token.dropFirst())
            var values: [CGFloat] = []
            let step = hex.count / 2 == 0 ? 1 : 2
            var units = hex.map(String.init)
            if step == 1 { units = units.flatMap { [$0, $0] } }
            guard units.count == 6 || units.count == 8 else { return nil }
            var index = 0
            while index < units.count {
                guard let value = UInt8(units[index] + units[index + 1], radix: 16) else {
                    return nil
                }
                values.append(CGFloat(value) / 255)
                index += 2
            }
            return NSColor(
                calibratedRed: values[0], green: values[1], blue: values[2],
                alpha: values.count > 3 ? values[3] : 1)
        }
        guard let open = token.firstIndex(of: "(") else { return nil }
        let kind = token[..<open].lowercased()
        let body = token[token.index(after: open)..<(token.lastIndex(of: ")") ?? token.endIndex)]
        let parts = body.split(whereSeparator: { $0 == "," }).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        func component(_ part: String) -> CGFloat? {
            if part.hasSuffix("%") {
                guard let value = Double(part.dropLast()) else { return nil }
                return CGFloat(value / 100)
            }
            guard let value = Double(part) else { return nil }
            return CGFloat(value)
        }
        guard parts.count >= 3, let first = component(parts[0]),
            let second = component(parts[1]), let third = component(parts[2])
        else { return nil }
        let alpha: CGFloat = parts.count > 3 ? (component(parts[3]) ?? 1) : 1
        if kind.hasPrefix("rgb") {
            return NSColor(
                calibratedRed: min(first, 255) / 255, green: min(second, 255) / 255,
                blue: min(third, 255) / 255, alpha: min(alpha, 1))
        }
        guard kind.hasPrefix("hsl") else { return nil }
        let hue = (first.truncatingRemainder(dividingBy: 360)) / 360
        let sat = min(max(second, 0), 1)
        let light = min(max(third, 0), 1)
        let chroma = (1 - abs(2 * light - 1)) * sat
        let huePrime = hue * 6
        let secondary = chroma * (1 - abs(huePrime.truncatingRemainder(dividingBy: 2) - 1))
        let match: [CGFloat]
        switch huePrime {
        case ..<1: match = [chroma, secondary, 0]
        case ..<2: match = [secondary, chroma, 0]
        case ..<3: match = [0, chroma, secondary]
        case ..<4: match = [0, secondary, chroma]
        case ..<5: match = [secondary, 0, chroma]
        default: match = [chroma, 0, secondary]
        }
        let bias = light - chroma / 2
        return NSColor(
            calibratedRed: min(max(match[0] + bias, 0), 1),
            green: min(max(match[1] + bias, 0), 1),
            blue: min(max(match[2] + bias, 0), 1),
            alpha: min(alpha, 1))
    }

    /// One bracket pair for the guides pass: opener/closer offsets and
    /// the opener's nesting depth (guides take the pair's depth color).
    private struct BracketPair {
        let open: Int
        let close: Int
        let depth: Int
    }

    /// Vertical guides spanning bracket pairs: for every pair whose opener and closer are
    /// in the laid-out range, a faint hairline at the opener's indent column
    /// on each line from the opener line up to (not including) the closer
    /// line - the bar stops above the closing bracket's row - in the same
    /// neutral paint as the indent guides. Background layer, beside them.
    private func drawBracketGuides(dirtyRect: NSRect) {
        guard let coordinator = editorCoordinator, coordinator.parent.bracketGuides,
            let layoutManager, let container = textContainer, !string.isEmpty
        else { return }
        let ns = string as NSString
        let length = ns.length
        guard length <= 20_000 else { return }  // hosts are short; the
        // whole-document pair walk is user-scale at this size.
        var stack: [(unit: unichar, index: Int)] = []
        var pairs: [BracketPair] = []
        let openers: [unichar] = [
            UInt16(UnicodeScalar("(").value), UInt16(UnicodeScalar("[").value),
            UInt16(UnicodeScalar("{").value),
        ]
        let closers: [unichar] = [
            UInt16(UnicodeScalar(")").value), UInt16(UnicodeScalar("]").value),
            UInt16(UnicodeScalar("}").value),
        ]
        for index in 0..<length {
            let unit = ns.character(at: index)
            if openers.contains(unit) {
                stack.append((unit, index))
            } else if let slot = closers.firstIndex(of: unit),
                let top = stack.last,
                top.unit == openers[slot]
            {
                stack.removeLast()
                if pairs.count < 500 {
                    pairs.append(
                        BracketPair(open: top.index, close: index, depth: stack.count + 1))
                }
            }
        }
        guard !pairs.isEmpty else { return }
        let tabSize = max(coordinator.indent.tabSize, 1)
        let spaceWidth = coordinator.spaceWidth(for: font ?? Self.fallbackFont)
        let unitWidth = spaceWidth * CGFloat(tabSize)
        let baseX = textContainerOrigin.x
        // Same neutral paint as the indent guides: VS Code's guides are
        // subtle monochrome lines, not per-depth colored ones.
        let neutralColor = EditorTheme.textPrimaryNS.withAlphaComponent(0.15)
        let bounding = dirtyRect.offsetBy(
            dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: bounding, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard charRange.length > 0 else { return }
        // Monaco `guides.bracketPairs: "active"`: ONE bar, for the
        // innermost pair whose bracket lines contain the caret's line.
        let caretRange = selectedRange()
        let caretLine = ns.lineRange(
            for: NSRange(location: min(max(caretRange.location, 0), length), length: 0))
        func containsCaretLine(_ pair: BracketPair) -> Bool {
            let openLine = ns.lineRange(for: NSRange(location: pair.open, length: 0))
            let closeLine = ns.lineRange(for: NSRange(location: pair.close, length: 0))
            return caretLine.location >= openLine.location
                && caretLine.location < NSMaxRange(closeLine)
        }
        guard
            let active =
                pairs
                .filter({ $0.depth > 0 && containsCaretLine($0) })
                .min(by: { ($1.close - $1.open) < ($0.close - $0.open) })
        else { return }
        // The opener's indent column on the SAME grid as the indent
        // guides: the leading whitespace of the opener's line, walked
        // unit by unit.
        let openLine = ns.lineRange(for: NSRange(location: active.open, length: 0))
        let closeLine = ns.lineRange(for: NSRange(location: active.close, length: 0))
        let openLead = ns.substring(with: openLine).prefix(while: { $0 == " " || $0 == "\t" })
        var openTotal = 0
        var spaces = 0
        for character in openLead {
            switch character {
            case " ":
                spaces += 1
                if spaces >= tabSize {
                    spaces = 0
                    openTotal += 1
                }
            case "\t":
                spaces = 0
                openTotal += 1
            default:
                break
            }
        }
        let columnX = (baseX + CGFloat(openTotal) * unitWidth).rounded()
        neutralColor.setFill()
        // Every laid-out fragment STRICTLY between the bracket lines: the
        // bar touches neither the opener nor the closer row (VS Code's
        // bracket-pair guides).
        var index = charRange.location
        let end = NSMaxRange(charRange)
        while index < end {
            var fragmentGlyphs = NSRange()
            let fragment = layoutManager.lineFragmentRect(
                forGlyphAt: index, effectiveRange: &fragmentGlyphs)
            let fragmentChars = layoutManager.characterRange(
                forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
            guard fragmentChars.location < length else { break }
            let fragmentLine = ns.lineRange(
                for: NSRange(location: fragmentChars.location, length: 0))
            if fragmentLine.location > NSMaxRange(openLine),
                fragmentLine.location < closeLine.location
            {
                NSRect(
                    x: columnX, y: fragment.minY + textContainerOrigin.y,
                    width: 1, height: fragment.height
                ).fill()
            }
            index = NSMaxRange(fragmentGlyphs)
        }
    }

    /// Faint pilcrow at the final newline.
    private func drawFinalNewline() {
        guard let coordinator = editorCoordinator,
            coordinator.parent.renderFinalNewline != .off,
            let layoutManager, let container = textContainer
        else { return }
        let length = (string as NSString).length
        guard length > 0,
            (string as NSString).character(at: length - 1) == UInt16(UnicodeScalar("\n").value)
        else { return }
        if coordinator.parent.renderFinalNewline == .boundary {
            let caretLine = coordinator.highlighter.lineNumber(ofUTF16Offset: selectedRange().location)
            let lastLine = coordinator.highlighter.lineNumber(ofUTF16Offset: length)
            guard caretLine == lastLine else { return }
        }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: length - 1)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1), in: container)
        let pilcrow = NSAttributedString(
            string: "¶",
            attributes: [
                .font: coordinator.textFont,
                .foregroundColor: NSColor(EditorTheme.textSecondary).withAlphaComponent(0.4),
            ])
        let size = pilcrow.size()
        pilcrow.draw(
            at: NSPoint(
                x: textContainerOrigin.x + glyphRect.maxX,
                y: textContainerOrigin.y + fragment.minY + (fragment.height - size.height) / 2))
    }

    /// Custom insertion point (shape + width + smooth animation).
    /// Only runs for the non-default shapes/widths or when smoothing is
    /// on; the system caret stays for `.line` at 1pt otherwise so
    /// defaults look exactly as before.
    private func drawCustomCaret() {
        guard let coordinator = editorCoordinator else { return }
        let parent = coordinator.parent
        let smooth = parent.cursorSmoothCaretAnimation != .off
        let custom = parent.cursorStyle != .line || parent.cursorWidth > 0 || smooth
        if !custom {
            if insertionPointColor == NSColor.clear {
                insertionPointColor = coordinator.insertionColorNS
            }
            Self.setBlinkTimerActive(false)
            return
        }
        guard window?.firstResponder === self, !hasMarkedText() else { return }
        // Blank the system caret; ours takes over.
        if insertionPointColor != NSColor.clear {
            insertionPointColor = NSColor.clear
        }
        Self.setBlinkTimerActive(parent.cursorBlinking == .blink)
        if parent.cursorBlinking == .blink, Self.customCaretBlinkOn == false,
            caretAnimationFrom == nil
        {
            return
        }
        guard let caret = caretDrawRect() else { return }
        coordinator.insertionColorNS.setFill()
        caret.fill()
    }

    /// The custom caret's rect in view coordinates (nil off the layout
    /// radar: no layout manager, empty document edge cases).
    private func caretDrawRect() -> NSRect? {
        guard let coordinator = editorCoordinator, let layoutManager,
            let container = textContainer
        else { return nil }
        let parent = coordinator.parent
        let caret = selectedRange().location
        let length = (string as NSString).length
        let probe = min(max(caret, 0), length)
        // Char-to-glyph mapping: end-of-text probes the LAST glyph so
        // the caret lands after it (an out-of-range glyph index would
        // give a zero rect).
        let afterEnd = probe >= length && length > 0
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: afterEnd ? length - 1 : probe)
        let fragmentRect = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex, effectiveRange: nil)
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1), in: container)
        let lineHeight = fragmentRect.height > 0 ? fragmentRect.height : glyphRect.height
        let originX = textContainerOrigin.x
        let caretX = afterEnd ? originX + glyphRect.maxX : originX + glyphRect.minX
        let caretY = textContainerOrigin.y + fragmentRect.minY
        let width = parent.cursorWidth > 0 ? parent.cursorWidth : 1
        let target: NSRect
        switch parent.cursorStyle {
        case .line:
            target = NSRect(x: caretX, y: caretY, width: width, height: lineHeight)
        case .block:
            target = NSRect(
                x: caretX, y: caretY, width: max(width, glyphRect.width), height: lineHeight)
        case .underline:
            target = NSRect(
                x: caretX, y: caretY + lineHeight - 2, width: max(width, glyphRect.width),
                height: 2)
        }
        // Smooth glide: ease the visual caret from the pre-change rect to
        // `target` over 120ms (same-line moves only; the starter guards the
        // line test). Logical selection is already at `target`.
        if let from = caretAnimationFrom, let start = caretAnimationStart {
            let progress = min(max(Date().timeIntervalSince(start) / 0.12, 0), 1)
            let eased = progress * progress * (3 - 2 * progress)
            return NSRect(
                x: from.minX + (target.minX - from.minX) * eased,
                y: target.minY,
                width: target.width,
                height: target.height)
        }
        return target
    }

    /// Repaints just the caret area (blink ticks, phase resets): a
    /// full-view invalidation twice a second would repaint every squiggle
    /// and indent guide for no visual change.
    func invalidateCaretRect() {
        let rect = caretDrawRect() ?? .zero
        let union = rect.union(lastCaretInvalidateRect)
        lastCaretInvalidateRect = rect
        guard !union.isEmpty else { return }
        setNeedsDisplay(union.insetBy(dx: -2, dy: -2))
    }

    private var lastCaretInvalidateRect: NSRect = .zero
    private static var customCaretBlinkOn = true
    private static var blinkTimer: Timer?
    /// Smooth-caret animation state (120ms same-line glide; off by
    /// default). `nil` from means "not animating". The tick chain is
    /// generation-stamped (`caretAnimationID`) so a fresh jump supersedes
    /// the previous one without a timer handle.
    private var caretAnimationFrom: NSRect?
    private var caretAnimationTo: NSRect?
    private var caretAnimationStart: Date?
    private var caretAnimationID = 0

    /// Starts a same-line caret glide from the pre-change to the
    /// post-change rect. Cross-line jumps, IME, and `.off` never animate;
    /// `.explicit` skips typing-driven moves.
    fileprivate func maybeStartCaretAnimation(from oldRect: NSRect?, to newRect: NSRect?) {
        guard let coordinator = editorCoordinator,
            coordinator.parent.cursorSmoothCaretAnimation != .off,
            let from = oldRect, let to = newRect,
            window != nil, !hasMarkedText()
        else { return }
        if coordinator.parent.cursorSmoothCaretAnimation == .explicit, isTypingKeystroke {
            return
        }
        guard abs(from.minX - to.minX) > 0.5, abs(from.minY - to.minY) < 1,
            abs(from.width - to.width) < 0.5 || true
        else { return }
        caretAnimationFrom = from
        caretAnimationTo = to
        caretAnimationStart = Date()
        scheduleCaretAnimationTimer()
    }

    private func scheduleCaretAnimationTimer() {
        caretAnimationID += 1
        let id = caretAnimationID
        guard let start = caretAnimationStart else { return }
        tickCaretAnimation(id: id, start: start)
    }

    private func tickCaretAnimation(id: Int, start: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.caretAnimationID == id else { return }
                if Date().timeIntervalSince(start) >= 0.12 {
                    self.caretAnimationFrom = nil
                    self.caretAnimationTo = nil
                    self.caretAnimationStart = nil
                    self.invalidateCaretRect()
                    return
                }
                self.invalidateCaretRect()
                self.tickCaretAnimation(id: id, start: start)
            }
        }
    }

    /// The blink ticker only exists while a custom caret is on screen;
    /// it flips the phase and repaints the caret rect of whichever editor
    /// holds key-window focus. Ticks on the common run-loop mode so it
    /// keeps blinking while the user scrolls.
    private static func setBlinkTimerActive(_ active: Bool) {
        if active {
            guard blinkTimer == nil else { return }
            customCaretBlinkOn = true
            let timer = Timer(timeInterval: 0.6, repeats: true) { _ in
                // Scheduled on the main run loop only.
                MainActor.assumeIsolated {
                    customCaretBlinkOn.toggle()
                    guard let textView = NSApp.keyWindow?.firstResponder as? EditorTextView
                    else { return }
                    textView.invalidateCaretRect()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            blinkTimer = timer
        } else if let timer = blinkTimer {
            timer.invalidate()
            blinkTimer = nil
            customCaretBlinkOn = true
        }
    }

    /// Whitespace markers: faint middots on
    /// whitespace (`.all` every unit, `.trailing` only the line-end run,
    /// `.boundary` leading/trailing/tabs/space-runs, `.selection` only
    /// inside the selection). Pure draw-layer work over the visible
    /// glyph range - no storage, no parse involvement.
    private func drawWhitespace(dirtyRect: NSRect) {
        let mode = editorCoordinator?.parent.renderWhitespace ?? .none
        guard mode != .none, let layoutManager, let container = textContainer,
            !string.isEmpty
        else { return }
        let ns = string as NSString
        let length = ns.length
        let bounding = dirtyRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: bounding, in: container)
        let markerColor = EditorTheme.textPrimaryNS.withAlphaComponent(0.18)
        markerColor.setFill()
        let selection = selectedRange()
        var index = glyphRange.location
        let end = NSMaxRange(glyphRange)
        while index < end {
            var fragmentGlyphs = NSRange()
            let lineFragment = layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: &fragmentGlyphs)
            let charRange = layoutManager.characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
            // Same layout-transient clamp as drawIndentGuides.
            guard charRange.location < length else { break }
            let clamped = NSRange(
                location: charRange.location,
                length: min(charRange.length, length - charRange.location))
            guard clamped.length > 0 else { break }
            let line = ns.substring(with: clamped) as NSString
            // Run boundaries per mode: where the trailing run starts, and
            // (boundary) where the leading run ends.
            var trailingStart = line.length
            if mode == .trailing || mode == .boundary {
                while trailingStart > 0 {
                    let unit = line.substring(with: NSRange(location: trailingStart - 1, length: 1))
                    guard unit == " " || unit == "\t" else { break }
                    trailingStart -= 1
                }
            }
            var leadingEnd = 0
            if mode == .boundary {
                while leadingEnd < line.length {
                    let unit = line.substring(with: NSRange(location: leadingEnd, length: 1))
                    guard unit == " " || unit == "\t" else { break }
                    leadingEnd += 1
                }
            }
            var offset = charRange.location
            for position in 0..<line.length {
                defer { offset += 1 }
                let unit = line.substring(with: NSRange(location: position, length: 1))
                guard unit == " " || unit == "\t" else { continue }
                let show: Bool
                switch mode {
                case .all:
                    show = true
                case .trailing:
                    show = offset - charRange.location >= trailingStart
                case .boundary:
                    // Tabs always show (they can double as separators);
                    // a space shows on the boundary runs or when it sits
                    // next to another whitespace unit (runs of 2+).
                    if unit == "\t" {
                        show = true
                    } else {
                        let inLeading = position < leadingEnd
                        let inTrailing = offset - charRange.location >= trailingStart
                        let neighborIsWhitespace: Bool
                        if position > 0 {
                            let prev = line.substring(with: NSRange(location: position - 1, length: 1))
                            neighborIsWhitespace = prev == " " || prev == "\t"
                        } else {
                            neighborIsWhitespace = false
                        }
                        show = inLeading || inTrailing || neighborIsWhitespace
                    }
                case .selection:
                    show = offset >= selection.location && offset < NSMaxRange(selection)
                case .none:
                    show = false
                }
                guard show else { continue }
                // Proportional position within the fragment: monospace font,
                // so character fraction == x fraction (good enough for a
                // 2pt marker; avoids per-glyph lookup churn).
                let fraction = CGFloat(offset - charRange.location) / CGFloat(max(line.length, 1))
                let marker = CGRect(
                    x: lineFragment.minX + textContainerOrigin.x + fraction * lineFragment.width,
                    y: lineFragment.minY + textContainerOrigin.y + lineFragment.height / 2 - 1,
                    width: 2,
                    height: 2)
                marker.fill()
            }
            index = NSMaxRange(fragmentGlyphs)
        }
    }

    /// Faint vertical guides at every completed indent level of each
    /// visible line fragment, drawn VS Code-style: one pixel-aligned bar
    /// per level at the indent column (`baseX + level * spaceWidth *
    /// tabSize`), spanning every line reaching the level. The leading
    /// whitespace is walked unit by unit against the configured
    /// `tabSize`: every `tabSize` spaces - or a literal tab, which
    /// renders at `tabSize` columns - completes one level. Wrapped
    /// continuations carry no leading whitespace and get none.
    private func drawIndentGuides(dirtyRect: NSRect) {
        guard let coordinator = editorCoordinator, coordinator.parent.indentGuides,
            let layoutManager = layoutManager, let container = textContainer,
            !string.isEmpty
        else { return }
        let nsString = string as NSString
        let length = nsString.length
        let tabSize = max(coordinator.indent.tabSize, 1)
        let spaceWidth = coordinator.spaceWidth(for: font ?? Self.fallbackFont)
        let unitWidth = spaceWidth * CGFloat(tabSize)
        let guideColor = EditorTheme.textPrimaryNS.withAlphaComponent(0.15)
        guideColor.setFill()
        let bounding = dirtyRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: bounding, in: container)
        var index = glyphRange.location
        let end = NSMaxRange(glyphRange)
        struct GuideSpan {
            var guideX: CGFloat
            var minY: CGFloat
            var maxY: CGFloat
        }
        var live: [Int: GuideSpan] = [:]
        var runs: [GuideSpan] = []
        func closeDeadLevels(above level: Int) {
            for key in live.keys.filter({ $0 > level }) {
                if let span = live.removeValue(forKey: key) {
                    runs.append(span)
                }
            }
        }
        while index < end {
            var fragmentGlyphs = NSRange()
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: &fragmentGlyphs)
            let charRange = layoutManager.characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
            // Layout transients (IME composition relayouts) can hand back
            // character ranges past the live storage - substring on those
            // throws, and a draw pass must never crash the app.
            guard charRange.location < length else { break }
            let clamped = NSRange(
                location: charRange.location,
                length: min(charRange.length, length - charRange.location))
            guard clamped.length > 0 else { break }
            // Guides at completed indent boundaries on a uniform grid:
            // level k sits at `baseX + k * unitWidth`, pixel-aligned.
            // baseX anchors on the CONTAINER origin — the same origin the
            // text cells start from (`lineFragmentPadding` is zeroed at
            // setup), with NO extra padding: an added inset shifts every
            // bar off the column it names. rulers use the same anchor
            // plus their own padding for their column semantics.
            // Spans merge across every line reaching the level, so each
            // block shows a continuous bar per level. The boundary at
            // the content column (k == total) gets a bar too - it is the
            // block edge. Capped at 12 levels.
            let baseX = textContainerOrigin.x
            var total = 0
            var spacesSeen = 0
            precount: for character in nsString.substring(with: clamped) {
                switch character {
                case " ":
                    spacesSeen += 1
                    if spacesSeen >= tabSize {
                        spacesSeen = 0
                        total += 1
                    }
                case "\t":
                    spacesSeen = 0
                    total += 1
                default:
                    break precount
                }
                if total >= 12 { break }
            }
            var levels = 0
            var spacesInUnit = 0
            let lineY = fragment.minY + textContainerOrigin.y
            let lineHeight = fragment.height
            // Fragment top → ink top: the line box piles leading above
            // the glyphs. Bars span the FULL line boxes of every line
            // reaching the level, from the first one's fragment top
            // through the last one's fragment bottom - no trims, no
            // extensions (Monaco's guides do the same).
            func noteGuide(_ level: Int) {
                guard level <= 12 else { return }
                // AT the level's content column (Monaco `guides.
                // indentation`): the bar hugs the characters that start
                // each indent level.
                let guideX = (baseX + CGFloat(level - 1) * unitWidth).rounded()
                if let known = live[level] {
                    var span = known
                    span.minY = min(span.minY, lineY)
                    span.maxY = max(span.maxY, lineY + lineHeight)
                    live[level] = span
                } else {
                    live[level] = GuideSpan(
                        guideX: guideX,
                        minY: lineY,
                        maxY: lineY + lineHeight)
                }
            }
            scan: for character in nsString.substring(with: clamped) {
                switch character {
                case " ":
                    spacesInUnit += 1
                    if spacesInUnit >= tabSize {
                        spacesInUnit = 0
                        levels += 1
                        noteGuide(levels)
                    }
                case "\t":
                    spacesInUnit = 0
                    levels += 1
                    noteGuide(levels)
                default:
                    break scan
                }
                if levels >= 12 { break }
            }
            closeDeadLevels(above: levels)
            index = NSMaxRange(fragmentGlyphs)
        }
        runs.append(contentsOf: live.values)
        for span in runs {
            NSRect(x: span.guideX, y: span.minY, width: 1, height: span.maxY - span.minY).fill()
        }
    }

    /// Recomputes the caret line's band and invalidates the old and new
    /// rects. Called on selection changes and after edits.
    func refreshLineBand() {
        let previous = lineBandRect
        lineBandRect = Self.computeLineBand(for: self)
        if previous != lineBandRect {
            setNeedsDisplay(previous.insetBy(dx: -2, dy: -2))
            setNeedsDisplay(lineBandRect.insetBy(dx: -2, dy: -2))
        }
        // Selection-scoped whitespace markers repaint on every caret move.
        if editorCoordinator?.parent.renderWhitespace == .selection {
            setNeedsDisplay(visibleRect)
        }
    }

    private static func computeLineBand(for textView: NSTextView) -> NSRect {
        guard let layoutManager = textView.layoutManager,
            !textView.string.isEmpty
        else { return .zero }
        let length = (textView.string as NSString).length
        let caret = min(textView.selectedRange().location, length)
        // Monaco's line highlight spans the full editor width, not just
        // the laid-out text: stretch the band's right edge to the view's
        // right edge (at least as wide as the text itself, so long
        // unwrapped lines are untouched).
        func fullWidth(_ band: NSRect) -> NSRect {
            let right = max(band.maxX, textView.bounds.maxX)
            return NSRect(
                x: band.minX, y: band.minY, width: right - band.minX,
                height: band.height)
        }
        // Caret on the phantom line (document ends with a newline): the
        // empty last line has no laid-out fragment of its own - the
        // layout manager's extra line fragment is its band.
        if caret == length, layoutManager.extraLineFragmentTextContainer != nil {
            return fullWidth(
                layoutManager.extraLineFragmentRect.offsetBy(
                    dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y))
        }
        let charRange = (textView.string as NSString).lineRange(for: NSRange(location: caret, length: 0))
        guard charRange.length > 0 else { return .zero }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var band = NSRect.zero
        var first = true
        var index = glyphRange.location
        let end = NSMaxRange(glyphRange)
        while index < end {
            var fragmentGlyphs = NSRange()
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: &fragmentGlyphs)
            // Fragment rects live in the container's coordinates.
            let viewRect = fragment.offsetBy(
                dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            band = first ? viewRect : band.union(viewRect)
            first = false
            index = NSMaxRange(fragmentGlyphs)
        }
        let stretched = fullWidth(band)
        // Monaco's highlight box is the line height (fontSize × 1.5,
        // rounded): taller than the glyph box, centered on the line.
        // Wrapped multi-fragment unions are already taller and stay.
        let fontSize =
            (textView as? EditorTextView)?.editorCoordinator?.parent.font.nsFont.pointSize
            ?? (textView as? EditorTextView)?.font?.pointSize ?? 13
        let boxHeight = (fontSize * 1.5).rounded()
        guard boxHeight > stretched.height else { return stretched }
        let centered = stretched.minY + (stretched.height - boxHeight) / 2
        return NSRect(
            x: stretched.minX, y: centered, width: stretched.width, height: boxHeight)
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let coordinator = editorCoordinator else { return menu }
        let editable = isEditable

        func item(_ title: String, _ key: String, _ mask: NSEvent.ModifierFlags, _ action: Selector, _ enabled: Bool) {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
            menuItem.keyEquivalentModifierMask = mask
            menuItem.target = self
            menuItem.isEnabled = enabled
            menu.addItem(menuItem)
        }

        menu.addItem(.separator())
        item("Format", "f", [.option, .shift], #selector(menuFormat), editable && coordinator.canFormat(self))
        item("Toggle Comment", "/", [.command], #selector(menuToggleComment), editable && coordinator.supportsComments)
        item(
            "Toggle Block Comment", "a", [.option, .shift], #selector(menuToggleBlockComment), editable && coordinator.supportsBlockComment)
        menu.addItem(.separator())
        item("Duplicate Lines", "d", [.command], #selector(menuDuplicateLines), editable)
        item("Delete Lines", "k", [.command, .shift], #selector(menuDeleteLines), editable)
        item("Delete to Line End", "k", [.control], #selector(menuDeleteToLineEnd), editable)
        let upKey = String(UnicodeScalar(NSUpArrowFunctionKey) ?? "?")
        let downKey = String(UnicodeScalar(NSDownArrowFunctionKey) ?? "?")
        item("Move Line Up", upKey, [.control, .command], #selector(menuMoveLinesUp), editable)
        item("Move Line Down", downKey, [.control, .command], #selector(menuMoveLinesDown), editable)
        menu.addItem(.separator())
        item("Transform to Uppercase", "", [], #selector(menuUppercaseLines), editable)
        item("Transform to Lowercase", "", [], #selector(menuLowercaseLines), editable)
        item("Sort Lines A–Z", "", [], #selector(menuSortAscending), editable)
        item("Sort Lines Z–A", "", [], #selector(menuSortDescending), editable)
        item("Join Lines", "", [], #selector(menuJoinLines), editable)
        item("Trim Trailing Whitespace", "", [], #selector(menuTrimWhitespace), editable)
        menu.addItem(.separator())
        item("Paste and Format", "v", [.command, .option, .shift], #selector(menuPasteAndFormat), editable && coordinator.canFormat(self))
        item("Go to Line…", "l", [.command, .option], #selector(menuGoToLine), true)
        item("Use Selection for Find", "e", [.command, .option], #selector(menuUseSelectionForFind), selectedRange().length > 0)
        item("Copy Line Up", upKey, [.option, .shift], #selector(menuCopyLinesUp), editable)
        item("Copy Line Down", downKey, [.option, .shift], #selector(menuCopyLinesDown), editable)
        item("Select Next Match", "d", [.control, .command], #selector(menuSelectNextMatch), true)
        item("Select Previous Match", "d", [.control, .command, .shift], #selector(menuSelectPreviousMatch), true)
        item("Go to Next Diagnostic", "", [], #selector(menuNextDiagnostic), !coordinator.diagnosticEntries.isEmpty)
        item("Go to Previous Diagnostic", "", [], #selector(menuPreviousDiagnostic), !coordinator.diagnosticEntries.isEmpty)
        item("Zoom In", "=", [.control], #selector(menuZoomIn), true)
        item("Zoom Out", "-", [.option, .control], #selector(menuZoomOut), true)
        item("Zoom to Actual Size", "0", [.control], #selector(menuZoomReset), true)
        item("Toggle Word Wrap", "z", [.option], #selector(menuToggleWordWrap), true)
        item("Transpose Characters", "t", [.control], #selector(menuTransposeCharacters), editable)
        item("Go to Definition", "", [], #selector(menuGoToDefinition), coordinator.parent.definitionProvider != nil)
        item("Go Back", "-", [.control], #selector(menuNavigateBack), coordinator.canNavigateBack)
        item("Go Forward", "-", [.control, .shift], #selector(menuNavigateForward), coordinator.canNavigateForward)
        item("Document Symbols", "o", [.control, .shift], #selector(menuOutline), true)
        item("Signature Help", " ", [.control, .shift], #selector(menuSignature), coordinator.parent.signatureProvider != nil)
        if !coordinator.parent.actions.isEmpty {
            menu.addItem(.separator())
            for action in coordinator.parent.actions {
                let hostItem = NSMenuItem(
                    title: action.title, action: #selector(menuRunHostAction(_:)),
                    keyEquivalent: action.key ?? "")
                hostItem.keyEquivalentModifierMask = action.modifiers
                hostItem.representedObject = action.id
                hostItem.target = self
                menu.addItem(hostItem)
            }
        }
        return menu
    }

    @objc private func menuRunHostAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
            let coordinator = editorCoordinator,
            let action = coordinator.parent.actions.first(where: { $0.id == id })
        else { return }
        action.run()
    }

    @objc private func menuFormat() { _ = editorCoordinator?.applyFormat(self) }
    @objc private func menuToggleComment() { _ = editorCoordinator?.toggleComment(self) }
    @objc private func menuToggleBlockComment() { _ = editorCoordinator?.toggleExplicitBlockComment(self) }
    @objc private func menuDuplicateLines() { editorCoordinator?.duplicateLines(in: self) }
    @objc private func menuDeleteLines() { editorCoordinator?.deleteLines(in: self) }
    @objc private func menuDeleteToLineEnd() { editorCoordinator?.deleteToLineEnd(in: self) }
    @objc private func menuMoveLinesUp() { editorCoordinator?.moveLines(in: self, up: true) }
    @objc private func menuMoveLinesDown() { editorCoordinator?.moveLines(in: self, up: false) }
    @objc private func menuUppercaseLines() { editorCoordinator?.uppercaseLines(in: self) }
    @objc private func menuLowercaseLines() { editorCoordinator?.lowercaseLines(in: self) }
    @objc private func menuSortAscending() { editorCoordinator?.sortLines(in: self, descending: false) }
    @objc private func menuSortDescending() { editorCoordinator?.sortLines(in: self, descending: true) }
    @objc private func menuJoinLines() { editorCoordinator?.joinLines(in: self) }
    @objc private func menuTrimWhitespace() { editorCoordinator?.trimTrailingWhitespace(in: self) }
    @objc private func menuFind() { editorCoordinator?.requestFind(replaceMode: false, in: self) }
    @objc private func menuPasteAndFormat() { editorCoordinator?.pasteAndFormat(in: self) }
    @objc private func menuGoToLine() { editorCoordinator?.requestLinePanel(in: self) }
    @objc private func menuUseSelectionForFind() { editorCoordinator?.useSelectionForFind(in: self) }
    @objc private func menuCopyLinesUp() { editorCoordinator?.copyLines(in: self, up: true) }
    @objc private func menuCopyLinesDown() { editorCoordinator?.copyLines(in: self, up: false) }
    @objc private func menuSelectNextMatch() { editorCoordinator?.selectNextMatch(in: self) }
    @objc private func menuSelectPreviousMatch() { editorCoordinator?.selectPreviousMatch(in: self) }
    @objc private func menuNextDiagnostic() { editorCoordinator?.goToDiagnostic(in: self, up: false) }
    @objc private func menuPreviousDiagnostic() { editorCoordinator?.goToDiagnostic(in: self, up: true) }
    @objc private func menuZoomIn() { editorCoordinator?.zoom(in: self) }
    @objc private func menuZoomOut() { editorCoordinator?.zoomOut(in: self) }
    @objc private func menuZoomReset() { editorCoordinator?.zoomReset(in: self) }
    @objc private func menuToggleWordWrap() { editorCoordinator?.toggleWordWrap(in: self) }
    @objc private func menuTransposeCharacters() { editorCoordinator?.transposeCharacters(in: self) }
    @objc private func menuGoToDefinition() { editorCoordinator?.goToDefinition(in: self) }
    @objc private func menuNavigateBack() { editorCoordinator?.navigateBack(in: self) }
    @objc private func menuNavigateForward() { editorCoordinator?.navigateForward(in: self) }
    @objc private func menuOutline() { editorCoordinator?.requestDocumentSymbols(in: self) }
    @objc private func menuSignature() { editorCoordinator?.signatureHelp.showExplicitly(in: self) }

    /// True only while `keyDown` is on the stack (see its override).
    /// IME commits arrive through TSM callbacks outside any keyDown, so
    /// they never see this flag - pairing never touches composed text,
    /// whatever replacementRange the input method passes.
    private var isTypingKeystroke = false

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func unmarkText() {
        super.unmarkText()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        // Read-only interception first: every
        // edit path funnels here, so one guard covers typing, paste, IME
        // commits, and drops.
        guard isEditable else {
            editorCoordinator?.notifyReadOnlyAttempt()
            return
        }
        // Smart pairs only for a single plain character synchronously
        // driven by a physical keystroke; everything else (paste,
        // completion acceptance, IME commits, attributed strings) takes
        // the standard path untouched.
        guard isTypingKeystroke,
            let coordinator = editorCoordinator,
            let string = insertString as? String,
            string.count == 1, let character = string.first,
            replacementRange.location == NSNotFound
        else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        if coordinator.handleTypedCharacter(character, in: self) {
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }
}

// MARK: - Coordinator

@MainActor
final class EditorCoordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    var parent: EditorRepresentable
    fileprivate let suggest: (any EditorSuggestControlling)?
    let highlighter: SourceHighlighter
    fileprivate var lastRestyleKey: String
    fileprivate var lastSyntax: SyntaxProfile
    weak var rootView: EditorRootView?
    private var lastReportedHeight: CGFloat = 0
    /// The scroll-overrun padding this coordinator last applied (zero
    /// while `scrollBeyondLastLine` is off); the transition into/out of
    /// managing the document's minSize is edge-triggered on it.
    private var lastScrollOverrun: CGFloat = 0
    /// Clickable-link temporary-attribute ranges, for
    /// removal before the next scan (edits shift ranges under them).
    private var linkRanges: [NSRange] = []
    private var lastLinksEnabled: Bool?
    /// Bracket-pair colorization ranges,
    /// tracked for removal like the links.
    var bracketColorRanges: [NSRange] = []
    /// A diagnostics pass that fired while the view was still windowless
    /// (the initial fill); flushed on the first in-window pass.
    var pendingDiagnosticsRefresh = false
    /// The signature-help popup (one per editor); nil provider leaves
    /// it permanently hidden.
    let signatureHelp = SignatureHelpController()
    /// Last processed outline pick, so re-renders do not re-jump.
    fileprivate var lastProcessedOutlineRange: NSRange?

    /// Runs the deferred diagnostics pass once the view has a window.
    func flushPendingDiagnostics(in textView: NSTextView) {
        guard pendingDiagnosticsRefresh, textView.window != nil else { return }
        pendingDiagnosticsRefresh = false
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, let textView, textView.window != nil else { return }
            self.refreshDiagnostics(in: textView)
            if parent.find.visible {
                self.refreshFindHighlights(in: textView)
            }
        }
    }
    /// Smart-select expansion chain:
    /// the seed through the whole document, and the live index into it.
    /// Re-seeded lazily whenever the live selection drifts off the head.
    var smartSelectChain: [NSRange] = []
    var smartSelectPosition: Int = 0
    /// The font this editor's text renders in: the balanced-metrics family
    /// (vertical centering, see `EditorFontBalancing`) when the host
    /// installed it, else the slot's stock `nsFont` face - then the
    /// ligature-enabled variant on top (base monospaced fonts render
    /// without ligatures, so the flag only ever enables). Balancing is
    /// scoped HERE, to the text this editor draws: `EditorFont.nsFont`
    /// stays stock so host surfaces borrowing the descriptor (URL bars,
    /// fields) never see the remapped metrics. Cached per host font.
    var textFont: NSFont {
        let slot = parent.font
        let base =
            EditorFontBalancing.font(size: slot.size, weight: slot.weight)
            ?? slot.nsFont
        guard parent.fontLigatures else { return base }
        if ligatureFontSource == base, let cached = ligatureFontCache {
            return cached
        }
        let descriptor = base.fontDescriptor.addingAttributes([
            .featureSettings: [
                [
                    NSFontDescriptor.FeatureKey.typeIdentifier: kLigaturesType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kCommonLigaturesOnSelector,
                ]
            ]
        ])
        let font = NSFont(descriptor: descriptor, size: base.pointSize) ?? base
        ligatureFontSource = base
        ligatureFontCache = font
        return font
    }
    private var ligatureFontSource: NSFont?
    private var ligatureFontCache: NSFont?
    /// The shared paragraph style: tab stops from `indent` plus the
    /// host's line-height multiplier. Rebuilt on access - it is a small
    /// object, and the restyle funnel runs per edit burst, not per glyph.
    var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.defaultTabInterval = spaceWidth(for: parent.font.nsFont) * CGFloat(max(indent.tabSize, 1))
        style.lineHeightMultiple = parent.lineHeightMultiple
        return style
    }
    /// Editor-local find state: all matches of the active query, the
    /// selected one, and the last mirrored find state (for diffing).
    var findMatches: [NSRange] = []
    var findCurrentIndex: Int?
    var lastFindState: EditorFindState?
    /// The last visible find state, kept so ⌘G/⌘⇧G still navigate after
    /// the bar is dismissed (Monaco keeps the last search). Scope is
    /// dropped on reuse (offsets go stale as the document edits); the
    /// query/options are what survive.
    var retainedFindState: EditorFindState?
    /// True while a formatting edit is in flight; `formatOnType` skips
    /// rescheduling its own echo, and paste-formatted inserts skip the
    /// debounced whole-document pass.
    var isFormatting = false
    /// Pending debounced `formatOnType` pass; cancelled on each edit.
    var formatOnTypeTask: Task<Void, Never>?
    /// The currently highlighted bracket pair (temporary attributes).
    var bracketHighlightRanges: [NSRange] = []
    /// The currently washed word-occurrence ranges (temporary attributes).
    var wordHighlightRanges: [NSRange] = []
    /// The currently dashed diagnostic-underline ranges (temporary attributes).
    var diagnosticUnderlineRanges: [NSRange] = []
    /// The live rendered diagnostics behind the underlines: host markers
    /// first, then the parse's syntax errors - range, message, severity
    /// (parallel to `diagnosticUnderlineRanges`).
    var diagnosticEntries: [DiagnosticEntry] = []
    /// The last reported stats, so repeated identical reports are dropped.
    private var lastStats: Editor.Stats?

    /// Reports document size + caret position. Zero new computation: reads the
    /// highlighter's line ledger that the gutter already maintains.
    func reportStats(in textView: NSTextView) {
        guard let onStatsChange = parent.onStatsChange else { return }
        let ns = textView.string as NSString
        let caret = min(textView.selectedRange().location, ns.length)
        let line = highlighter.lineNumber(ofUTF16Offset: caret)
        let lineStart = highlighter.lineStartOffsets[max(0, line - 1)]
        let stats = Editor.Stats(
            lines: highlighter.lineCount,
            characters: ns.length,
            line: line,
            column: caret - lineStart + 1)
        guard stats != lastStats else { return }
        lastStats = stats
        // Publish on the next runloop turn: onStatsChange mutates host
        // SwiftUI state, and reportStats runs inside view-update
        // transactions (makeNSView's initial fill, updateNSView passes)
        // where a synchronous publish is swallowed ("will not be
        // displayed") - hosts would see no stats until the first
        // selection change or edit that moved the caret.
        DispatchQueue.main.async { onStatsChange(stats) }
    }
    /// Last processed find/goto actions so synchronous SwiftUI-state
    /// clears (dropped inside update transactions) do not re-trigger.
    fileprivate var lastProcessedFindAction: EditorFindAction?
    /// Navigation history for ⌃-/⌃⇧- (Monaco `navigateBack`/`navigateForward`):
    /// selections captured before a programmatic jump, so the editor can
    /// walk through the jumps it made. Selection-only navigations.
    var navigationBackStack: [NSRange] = []
    var navigationForwardStack: [NSRange] = []
    /// The host markers currently rendered (diffed in updateNSView so a
    /// new array re-runs the squiggle pass).
    var hostMarkers: [EditorMarker] = []
    var lastHostMarkers: [EditorMarker] = []
    /// Indentation configuration (`tabSize` + `insertSpaces`),
    /// possibly overridden by `detectIndentation` on first fill.
    struct IndentConfiguration: Equatable {
        var tabSize: Int
        var insertSpaces: Bool
    }
    var indent = IndentConfiguration(tabSize: 2, insertSpaces: true)
    /// The detect-once latch: after the first fill's detection the
    /// document's own style wins over later host value changes.
    var didDetectIndentation = false
    /// Last applied wrap mode (updateNSView diff).
    var lastWordWrap: EditorWordWrap?
    /// The overview-ruler strip width last applied to the wrap reserve.
    var lastWrapReserve: CGFloat = 0
    /// The indent unit typed by Tab and brace expansion: `tabSize`
    /// spaces, or one tab character.
    var indentUnit: String {
        indent.insertSpaces
            ? String(repeating: " ", count: max(indent.tabSize, 1))
            : "\t"
    }
    /// The rendered advance of one space at `font` (guides + tab stops).
    func spaceWidth(for font: NSFont) -> CGFloat {
        max((" " as NSString).size(withAttributes: [.font: font]).width, 1)
    }
    /// Recomputes the floating bars' cursor exclusion rect and hands it to
    /// the text view. Called from `updateNSView` and on every scroll tick:
    /// the bars are pinned to the viewport while cursor rects live in the
    /// text view's (flipped, scroll-dependent) content coordinates, so the
    /// rect must be re-derived — through `convert(_:from:)`, which handles
    /// both the flip and the scroll offset — whenever either moves.
    func refreshCursorExclusion() {
        guard let root = rootView, let textView = root.textView as? EditorTextView else { return }
        let cardSize: CGSize?
        if parent.find.visible {
            cardSize = EditorFindBar.cardSize(replacing: parent.find.replacing)
        } else if parent.gotoVisible {
            cardSize = EditorGoToLineBar.cardSize()
        } else if parent.outlineVisible {
            cardSize = EditorDocumentSymbolsBar.cardSize()
        } else {
            cardSize = nil
        }
        guard let cardSize else {
            textView.cursorExclusionRect = .zero
            return
        }
        // The card in the ROOT's (bottom-left) coordinates: top-trailing
        // with the overlay's outer paddings.
        let rootRect = NSRect(
            x: root.bounds.width - EditorTheme.spaceMedium - cardSize.width,
            y: root.bounds.height - EditorTheme.spaceXSmall - cardSize.height,
            width: cardSize.width,
            height: cardSize.height)
        // Into the text view's flipped, scrolled system — this is the step
        // whose omission left the exclusion at the bottom of the editor.
        textView.cursorExclusionRect = textView.convert(rootRect, from: root)
    }

    /// Applies the shared paragraph style (tab stops + line-height) as the
    /// text view's default and typing attributes, and bakes it into the
    /// existing text whenever the style's identity changed: the default
    /// only governs text added afterwards, so an installed multiplier
    /// reaches the already-filled storage only through a restyle.
    func applyTabStops(to textView: NSTextView) {
        let style = paragraphStyle
        if textView.defaultParagraphStyle != style {
            textView.defaultParagraphStyle = style
            textView.typingAttributes = textView.typingAttributes.merging(
                [.paragraphStyle: style]) { _, new in new }
            refreshStyling(in: textView)
            textView.needsDisplay = true
        }
    }
    /// Applies the wrap mode: `.on` tracks the text
    /// view's width; `.off`/`.column(_)` release the container width so
    /// lines run long and the scroll view pans horizontally (overlay
    /// scroller enabled for the pan feedback).
    func applyWordWrap(_ wrap: EditorWordWrap, to textView: NSTextView) {
        let reserve: CGFloat = parent.showsOverviewRuler ? EditorOverviewRulerView.width : 0
        guard wrap != lastWordWrap || reserve != lastWrapReserve else { return }
        lastWordWrap = wrap
        lastWrapReserve = reserve
        let spaceWidth = spaceWidth(for: parent.font.nsFont)
        let containerWidth: CGFloat
        switch wrap {
        case .on:
            // Reserve the overview-ruler strip on the right so wrapped
            // text never runs under the transparent scrollbar; the line
            // band extends beneath it instead. Before the view is sized
            // (bounds 0) keep the auto-tracking path.
            containerWidth =
                parent.showsOverviewRuler && textView.bounds.width > 1
                ? textView.bounds.width - Editor.textInset.width * 2
                    - EditorOverviewRulerView.width
                : 0
        case .off: containerWidth = .greatestFiniteMagnitude
        case .column(let columns): containerWidth = CGFloat(max(columns, 1)) * spaceWidth
        }
        let tracksWidth = wrap == .on && containerWidth == 0
        let horizontallyResizable = wrap != .on
        if let container = textView.textContainer {
            if container.widthTracksTextView != tracksWidth {
                container.widthTracksTextView = tracksWidth
            }
            if container.containerSize.width != containerWidth {
                container.containerSize = NSSize(
                    width: containerWidth, height: container.containerSize.height)
            }
        }
        if textView.isHorizontallyResizable != horizontallyResizable {
            textView.isHorizontallyResizable = horizontallyResizable
            textView.autoresizingMask = horizontallyResizable ? [] : [.width]
        }
        if let scrollView = textView.enclosingScrollView,
            scrollView.hasHorizontalScroller != horizontallyResizable
        {
            scrollView.hasHorizontalScroller = horizontallyResizable
        }
        textView.needsLayout = true
        textView.needsDisplay = true
        reportContentHeight(textView)
    }
    /// Keeps the ruler strip reserved on the container's right edge as
    /// the view resizes (`.on` wrap runs with a manual container width
    /// while the ruler is shown). Called from the layout pass; the write
    /// only invalidates paint and re-reports the height.
    func refreshWrapReserve(_ textView: NSTextView?) {
        guard let textView, parent.showsOverviewRuler, parent.wordWrap == .on,
            textView.bounds.width > 1, let container = textView.textContainer
        else { return }
        let target =
            textView.bounds.width - Editor.textInset.width * 2
            - EditorOverviewRulerView.width
        if abs(container.containerSize.width - target) > 0.5 {
            container.containerSize = NSSize(
                width: target, height: container.containerSize.height)
            textView.needsLayout = true
            textView.needsDisplay = true
            reportContentHeight(textView)
        }
    }

    /// First-fill detection: the majority
    /// style of the document's leading whitespace wins; for spaces, the
    /// GCD of leading runs (clamped 1...8) is the unit.
    func detectIndentationIfNeeded(_ text: String) {
        guard parent.detectIndentation, !didDetectIndentation, !text.isEmpty else { return }
        didDetectIndentation = true
        var tabLines = 0
        var spaceLines = 0
        var runGCD = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(200) {
            if line.hasPrefix("\t") {
                tabLines += 1
                continue
            }
            let spaces = line.prefix(while: { $0 == " " }).count
            if spaces > 0 {
                spaceLines += 1
                runGCD = Self.gcd(runGCD, spaces)
            }
        }
        if tabLines > spaceLines {
            indent.insertSpaces = false
        } else if spaceLines > tabLines, runGCD > 0 {
            indent.tabSize = min(max(runGCD, 1), 8)
        }
    }
    private static func gcd(_ first: Int, _ second: Int) -> Int {
        var first = first
        var second = second
        while second != 0 { (first, second) = (second, first % second) }
        return first
    }
    /// The moment of the last storage edit (IME commit protection in
    /// updateNSView's replaceAll branch).
    var lastCommitTime: Date?
    /// Whether the most recent storage edit inserted non-ASCII (from the
    /// storage delegate's edited range) - gates the post-commit full restyle
    /// that regenerates zero-advance CJK glyphs.
    var lastEditHadNonASCII = false
    fileprivate var lastProcessedGotoLine: Int?
    fileprivate var lastProcessedGotoColumn: Int?
    var lastLineCountHint = 1
    /// The character index the diagnostic tooltip last resolved (dedupes
    /// provider calls on the same token).
    var lastHoverIndex: Int?

    /// The last text value synced from the editor's own input (typing,
    /// paste, IME commit). updateNSView skips replaceAll when the binding
    /// matches this, because that means the change came from the editor
    /// itself - not an external host update that needs to be pushed down.
    var lastSyncText: String?

    init(_ parent: EditorRepresentable) {
        self.parent = parent
        self.suggest = parent.suggestFactory?()
        self.lastRestyleKey = parent.restyleKey
        self.lastSyntax = parent.syntax
        self.hostMarkers = parent.markers
        self.highlighter = SourceHighlighter(profile: parent.syntax)
        super.init()
        signatureHelp.setProvider(parent.signatureProvider)
    }

    /// The caret color: the insertion-point token when the host set one,
    /// else the accent (Plume's historic behavior).
    var insertionColorNS: NSColor {
        EditorTheme.insertionPointColorNS ?? NSColor(EditorTheme.accent)
    }

    // MARK: Editor-local zoom

    /// Adjusts the SwiftUI-owned zoom factor (0.1 steps, 0.5…4 range).
    /// The coordinator computes the next factor and routes it through the
    /// Representable callback so the AppKit side never owns font state.
    func zoom(in textView: NSTextView) {
        _ = textView
        let next = Editor.normalizedFontScale(parent.fontScale + 0.1)
        if next != parent.fontScale { parent.onFontScaleChange?(next) }
    }

    func zoomOut(in textView: NSTextView) {
        _ = textView
        let next = Editor.normalizedFontScale(parent.fontScale - 0.1)
        if next != parent.fontScale { parent.onFontScaleChange?(next) }
    }

    func zoomReset(in textView: NSTextView) {
        _ = textView
        if parent.fontScale != 1 { parent.onFontScaleChange?(1) }
    }

    /// Option+Z: flips the line wrap (Monaco `toggleWordWrap`). Routes
    /// through SwiftUI-owned state so the Representable's host prop
    /// cannot silently revert the toggle on its next pass.
    func toggleWordWrap(in textView: NSTextView) {
        _ = textView
        let next: EditorWordWrap
        switch parent.wordWrap {
        case .on: next = .off
        case .off, .column: next = .on
        }
        parent.onWordWrapChange?(next)
    }

    // MARK: Document outline

    /// Ctrl+Shift+O: collects symbols (host provider, else built-in
    /// extraction) and hands them to the SwiftUI outline panel.
    func requestDocumentSymbols(in textView: NSTextView) {
        let symbols =
            parent.documentSymbolsProvider?(textView.string)
            ?? highlighter.documentSymbols(in: textView.string)
        parent.onDocumentSymbolsChanged?(symbols.sorted { $0.range.location < $1.range.location })
    }

    /// Outline pick: selects the picked range (Monaco `goToSymbol`).
    func goToOutlineRange(_ range: NSRange, in textView: NSTextView) {
        let length = (textView.string as NSString).length
        let clamped = range.clamped(to: length) ?? NSRange(location: min(range.location, length), length: 0)
        pushNavigationOrigin(in: textView)
        textView.setSelectedRange(clamped)
        reveal(clamped, in: textView)
    }

    /// Debounced `formatOnType`: cancels any pending pass and schedules a
    /// fresh whole-document format after 800ms of typing idle. Suppressed
    /// while a formatting edit itself is in flight (`isFormatting`), in
    /// read-only mode, mid-IME, or when the view has no window.
    func scheduleFormatOnType(in textView: NSTextView) {
        formatOnTypeTask?.cancel()
        guard parent.formatOnType, !isFormatting, textView.isEditable,
            parent.formatHandler != nil, !textView.hasMarkedText(),
            textView.window != nil
        else { return }
        formatOnTypeTask = Task { @MainActor [weak self, weak textView] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self, let textView else { return }
            guard textView.window != nil, textView.isEditable,
                !textView.hasMarkedText()
            else { return }
            self.isFormatting = true
            _ = self.applyFormat(textView)
            self.isFormatting = false
        }
    }

    // MARK: Text view delegate

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        lastCommitTime = Date()
        reportStats(in: textView)
        // Non-ASCII COMMIT (CJK IME): glyphs generated during the IME's
        // edit window come out zero-advance (the run squeezed into a
        // sliver, drawing nothing). After the composition is fully torn
        // down, rewriting the storage's attributes invalidates those
        // glyphs; the next layout regenerates them with a proper cascade.
        // The flag comes from the storage delegate's edit range, so plain
        // ASCII typing never pays for a full restyle.
        // Non-ASCII COMMIT (CJK IME): glyphs generated during the IME's
        // edit window can come out zero-advance (the run squeezed into a
        // sliver, drawing nothing). After the composition is fully torn
        // down, rewriting the storage's attributes invalidates those
        // glyphs; the next layout regenerates them with a proper cascade.
        // NEVER during composition: touching the marked range's attributes
        // mid-composition makes the input system re-anchor and reabsorb
        // freshly committed text (committed characters vanish until the
        // next commit). The flag comes from the storage delegate's edit
        // range, so plain ASCII typing never pays for a full restyle.
        if lastEditHadNonASCII, !textView.hasMarkedText() {
            lastEditHadNonASCII = false
            refreshStyling(in: textView)
        }
        parent.text = textView.string
        lastSyncText = textView.string
        // Suggest stays live during IME (candidate refilters are harmless);
        // bracket/word highlights write temporary attributes that would
        // fight the composition's own marked-range styling, so they wait.
        suggest?.textChanged(textView)
        signatureHelp.textChanged(textView)
        reportContentHeight(textView)
        invalidateGutter()
        (textView as? EditorTextView)?.refreshLineBand()
        guard !textView.hasMarkedText() else { return }
        updateBracketHighlight(in: textView)
        updateWordHighlight(in: textView)
        scheduleFormatOnType(in: textView)
        // IME commit: the caret just moved to the committed text, which
        // may sit below the visible area (long document, fillsContainer).
        // AppKit's implicit scroll doesn't fire for the NSNotFound
        // replacement path - scroll explicitly.
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// Caret moves (arrow keys, clicks): keep an open popup glued to the
    /// caret, refresh the current-line band and the bracket-pair highlight.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        suggest?.selectionChanged(textView)
        signatureHelp.selectionChanged(textView)
        reportStats(in: textView)
        (textView as? EditorTextView)?.refreshLineBand()
        updateBracketHighlight(in: textView)
        updateWordHighlight(in: textView)
        // Caret-line strip in the gutter (renderLineHighlight
        // .gutter/.all) repaints with the caret.
        invalidateGutter()
        if let callback = parent.onSelectionChange {
            let selection = textView.selectedRange()
            let length = (textView.string as NSString).length
            // Unclamped against length (the ledger clamps internally): a
            // caret on the phantom line after a trailing newline must
            // report that line, not the previous one.
            let offset = length > 0 ? min(selection.location, length) : 0
            let (line, column) = highlighter.lineAndColumn(ofUTF16Offset: offset)
            callback(
                EditorSelectionSnapshot(
                    line: line, column: column, length: selection.length))
        }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if suggest?.handleCommand(commandSelector) == true { return true }
        // Typing assists are gated: prose/paste surfaces keep the platform
        // defaults (plain newline, tab character, no comment toggle).
        guard parent.enablesTypingAssist else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            insertNewlineWithIndent(textView)
            return true
        case #selector(NSResponder.insertTab(_:)):
            indentSelection(textView, outdent: false)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            indentSelection(textView, outdent: true)
            return true
        default:
            return false
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        suggest?.hide()
    }

    // MARK: Paint pipeline (text-storage delegate)

    /// Single restyle funnel: every character edit - typing, paste, the
    /// smart-edit helpers, external replaces - lands here with the precise
    /// edited range. The highlighter folds the edit into its parse tree and
    /// returns the repaint window (edited lines ∪ the parse's changed
    /// ranges, line-aligned); this sets base attributes on the window and
    /// layers the syntax runs and the host's annotation washes that
    /// intersect it.
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        // Only character edits enter the pipeline; the attribute writes
        // below re-enter with .editedAttributes and must fall through.
        guard editedMask.contains(.editedCharacters) else { return }
        let text = textStorage.string
        let length = (text as NSString).length
        let result = highlighter.edit(text, editedRange: editedRange, delta: delta)

        // IME COMPOSITION: rewrite NOTHING. Any attribute write here (the
        // paint funnel covers the whole edited line, including previously
        // committed CJK on it) invalidates glyphs and regenerates them
        // inside the IME's edit window - where font cascade fails and CJK
        // comes out zero-advance (committed characters visually vanish
        // until the next commit's restyle). The parse tree above stays in
        // sync; styling catches up at the commit (textDidChange's full
        // restyle for non-ASCII edits, the normal funnel otherwise). The
        // marked pinyin itself carries typing attributes from the input
        // system and renders fine untouched.
        if let textView = rootView?.textView, textView.hasMarkedText() {
            invalidateGutter()
            return
        }

        // Annotation ranges come from the host's provider; any that touch
        // the window pull the window out to cover them whole, so a
        // multi-line annotation never ends up half-restyled.
        let tintRanges = parent.annotations?(text) ?? []
        var window = result.window
        for (range, _) in tintRanges where NSIntersectionRange(range, window).length > 0 {
            window = window.union(range)
        }
        guard let clampedWindow = window.clamped(to: length), clampedWindow.length > 0 else {
            return
        }

        // Flag for the post-commit restyle (textDidChange): the writes BELOW
        // invalidate glyphs and NSLayoutManager regenerates them
        // synchronously inside this edit transaction - where the font
        // cascade fails and CJK comes out zero-advance (the whole line
        // visually vanishes). textDidChange must re-style whenever the
        // rewritten window contains non-ASCII. The window, not the edit
        // range: a DELETION's edited range is empty (nothing occupies it
        // anymore), but the line it shrank still holds the CJK whose
        // glyphs the rewrite just broke. Scanned over one line, O(line).
        lastEditHadNonASCII = false
        let windowText = (text as NSString).substring(with: clampedWindow)
        for unit in windowText.utf16 where unit > 127 {
            lastEditHadNonASCII = true
            break
        }

        // Base attributes reset the window (inserted characters arrive
        // unattributed; pasted runs shed their fonts via isRichText=false,
        // and this normalizes anything else). The shared paragraph style
        // rides along so the host's line-height multiplier applies to the
        // whole window, not just newly typed text.
        textStorage.setAttributes(
            [.font: textFont, .foregroundColor: EditorTheme.textPrimaryNS, .paragraphStyle: paragraphStyle],
            range: clampedWindow)
        if let runs = result.runs {
            for (range, color) in runs {
                let intersection = NSIntersectionRange(range, clampedWindow)
                guard intersection.length > 0 else { continue }
                textStorage.addAttribute(.foregroundColor, value: color, range: intersection)
            }
        }
        for (range, color) in tintRanges {
            let intersection = NSIntersectionRange(range, clampedWindow)
            guard intersection.length > 0 else { continue }
            textStorage.addAttribute(
                .backgroundColor,
                value: color,
                range: intersection)
        }
        invalidateGutter()
        // Temporary attributes (diagnostics, find washes) translate
        // character ranges against the layout manager - which still holds
        // the PRE-edit layout while we are inside processEditing. During
        // that window any range can exceed the stale glyph count and throw
        // NSRangeException inside NSLayoutManager. Defer to the next
        // runloop turn: layout has run, the mapping is valid again.
        if let textView = rootView?.textView {
            let hasFind = parent.find.visible
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                // The fill happens before SwiftUI attaches the window;
                // defer to the first in-window pass (updateNSView /
                // viewDidMoveToWindow) instead of dropping the pass -
                // otherwise parse diagnostics never show until the first
                // edit.
                guard textView.window != nil else {
                    self.pendingDiagnosticsRefresh = true
                    return
                }
                self.refreshDiagnostics(in: textView)
                if hasFind {
                    self.refreshFindHighlights(in: textView)
                }
            }
        }
    }

    /// Full restyle for scope/kind switches (rare): the shared static
    /// one-shot walk over the whole text.
    func refreshStyling(in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.setAttributes(
            [.font: textFont, .foregroundColor: EditorTheme.textPrimaryNS, .paragraphStyle: paragraphStyle],
            range: full)
        if let runs = SyntaxHighlight.foregroundRuns(in: storage.string, profile: parent.syntax) {
            for (range, color) in runs {
                storage.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
        for (range, color) in parent.annotations?(storage.string) ?? [] {
            storage.addAttribute(
                .backgroundColor,
                value: color,
                range: range)
        }
    }

    /// External replace: swap the whole content through the standard
    /// pipeline (the storage delegate repaints), keep the caret when it
    /// still fits, retire the popup, refresh the height report.
    func replaceAll(_ text: String, in textView: NSTextView) {
        suggest?.hide()
        let selection = textView.selectedRange()
        guard let storage = textView.textStorage else { return }
        storage.setAttributedString(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: textFont,
                    .foregroundColor: EditorTheme.textPrimaryNS,
                    .paragraphStyle: paragraphStyle,
                ]))
        // Clamp against the storage's LIVE post-edit length, not the
        // parameter's: any drift between the two (a failed or partial set,
        // an observer that mutated the storage) must not produce an
        // out-of-bounds selection - AppKit computes the caret's blink rect
        // inside setSelectedRange and throws NSRangeException on OOB.
        let length = storage.length
        let caret = selection.location == NSNotFound ? length : min(max(selection.location, 0), length)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        lastRestyleKey = parent.restyleKey
        lastSyntax = parent.syntax
        reportStats(in: textView)
        reportContentHeight(textView)
        invalidateGutter()
    }

    func reportContentHeight(_ textView: NSTextView?) {
        guard let textView, let onContentHeightChange = parent.onContentHeightChange,
            let layoutManager = textView.layoutManager,
            let container = textView.textContainer
        else { return }
        // NSLayoutManager lays out lazily, only as far as the visible clip:
        // reading usedRect without forcing layout reports the CURRENT clip,
        // and the auto-grow loop then deadlocks at its starting height
        // (bigger clip → more laid out → bigger report → ... never starts).
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        // Top lives in the container inset (base + padding.top); the base
        // bottom inset and padding.bottom come in explicitly (auto-grow
        // reports the padding; scroll mode overfills via contentInsets).
        let height = ceil(
            used.height
                + textView.textContainerInset.height
                + Editor.textInset.height
                + parent.editorPadding.bottom)
        guard abs(height - lastReportedHeight) > 0.5 else { return }
        lastReportedHeight = height
        onContentHeightChange(height)
    }

    func invalidateGutter() {
        // Paint invalidation only - see the onLayout note: constraint or
        // frame changes from here (storage edits fire inside SwiftUI's
        // makeNSView/updateNSView transactions) would reschedule layout
        // mid-transaction and blank sibling SwiftUI rows.
        redrawGutter()
        rootView?.rulerView?.needsDisplay = true
    }

    func redrawGutter() {
        guard let gutter = rootView?.gutterView else { return }
        gutter.needsDisplay = true
    }

    /// A text-modifying key landed on a read-only editor: surface the
    /// host's notice (a bottom-trailing capsule) and fire the host callback.
    func notifyReadOnlyAttempt() {
        guard !parent.isEditable else { return }
        if let message = parent.readOnlyMessage {
            parent.onReadOnlyAttemptNotice?(message)
        }
        parent.onReadOnlyAttempt?(parent.readOnlyMessage ?? "")
    }

    /// Scroll-overrun padding (`scrollBeyondLastLine` /
    /// `scrollBeyondLastColumn` + `padding.bottom`). Auto-grow editors
    /// report the height instead (no scrollbar to overfill), so this is a
    /// no-op there. The overrun grows the DOCUMENT view (minSize/frame),
    /// NOT clip contentInsets: insets shrink the clip's hit-testable
    /// content area, so clicks anywhere below the first line land on the
    /// scroll view and the editor can never take focus (the Runlet
    /// "seems read-only" regression). Mutations go through the next
    /// runloop turn - see the onLayout note about mutating layout from
    /// inside the layout pass.
    func applyScrollBeyond(_ textView: NSTextView?) {
        guard let textView, parent.onContentHeightChange == nil,
            let scrollView = textView.enclosingScrollView,
            let layoutManager = textView.layoutManager,
            let container = textView.textContainer
        else { return }
        let lineHeight = layoutManager.defaultLineHeight(for: parent.font.nsFont)
        let overrun =
            parent.editorPadding.bottom
            + (parent.scrollBeyondLastLine
                ? max(scrollView.bounds.height - lineHeight, 0) : 0)
        guard overrun > 0.5 || lastScrollOverrun > 0.5 else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        let target = used + textView.textContainerInset.height * 2 + overrun
        lastScrollOverrun = overrun
        if abs(textView.minSize.height - target) > 0.5 || textView.frame.height < target - 0.5 {
            DispatchQueue.main.async { [weak textView] in
                guard let textView, textView.window != nil else { return }
                textView.minSize = NSSize(width: 0, height: target)
                if textView.frame.height < target {
                    textView.frame.size.height = target
                }
            }
        }
        // Horizontal overrun: widen the text view past its content so the
        // pan mode can scroll the trailing columns into view. AppKit only
        // ever GROWS a horizontally resizable text view, so the extra
        // width sticks across edits.
        guard parent.scrollBeyondLastColumn > 0, textView.isHorizontallyResizable else { return }
        let spaceWidth = spaceWidth(for: parent.font.nsFont)
        let needed =
            layoutManager.usedRect(for: container).width
            + textView.textContainerInset.width * 2
            + CGFloat(parent.scrollBeyondLastColumn) * spaceWidth
        if textView.frame.width < needed {
            DispatchQueue.main.async { [weak textView] in
                guard let textView, textView.window != nil else { return }
                textView.frame.size.width = max(textView.frame.width, needed)
            }
        }
    }

    /// Clickable links: URL-shaped runs get the `.link`
    /// temporary attribute (NSTextView opens them on plain click). Runs
    /// after every styling pass so it survives edits like the squiggles;
    /// short host documents keep the NSDataDetector sweep cheap.
    func applyLinks(in textView: NSTextView) {
        let length = (textView.string as NSString).length
        for range in linkRanges where NSMaxRange(range) <= length && range.length > 0 {
            textView.layoutManager?.removeTemporaryAttribute(.link, forCharacterRange: range)
        }
        linkRanges = []
        guard parent.linksEnabled, length > 0, let layoutManager = textView.layoutManager
        else { return }
        let full = NSRange(location: 0, length: length)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return }
        // NSDataDetector works on Strings, and UTF-16 ranges map 1:1 for
        // the link ranges it reports (they split on scalar boundaries).
        let matches = detector.matches(
            in: textView.string, range: full)
        var ranges: [NSRange] = []
        for match in matches.prefix(200) {
            guard match.resultType == .link, let url = match.url else { continue }
            var range = match.range
            if NSMaxRange(range) > length {
                range = NSRange(location: range.location, length: max(0, length - range.location))
            }
            guard range.length > 0, range.length <= 2000 else { continue }
            layoutManager.addTemporaryAttribute(.link, value: url, forCharacterRange: range)
            ranges.append(range)
        }
        linkRanges = ranges
    }

    /// Called from updateNSView when `linksEnabled` flips without an edit
    /// in between (edits re-apply through refreshDiagnostics anyway).
    func syncLinks(in textView: NSTextView) {
        if parent.linksEnabled {
            textView.linkTextAttributes = [
                .foregroundColor: NSColor(EditorTheme.accent),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        }
        guard lastLinksEnabled != parent.linksEnabled else { return }
        lastLinksEnabled = parent.linksEnabled
        applyLinks(in: textView)
    }

    /// Plain click on a `.link` range: open it. Only reachable when
    /// `linksEnabled` (link attributes exist only then).
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard parent.linksEnabled, let url = link as? URL else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    // MARK: ⌥⇧F formatting

    /// Runs the caller's handler over the text as one undoable step.
    /// Returns false when no handler is installed (the key falls through).
    func applyFormat(_ textView: NSTextView) -> Bool {
        guard textView.isEditable, let formatHandler = parent.formatHandler else { return false }
        do {
            guard let formatted = try formatHandler(textView.string) else { return true }
            let caret = textView.selectedRange().location
            let sourceRange = NSRange(location: 0, length: (textView.string as NSString).length)
            // Registers the undo entry, then the storage edit funnels the
            // replacement through the repaint pipeline via didChangeText.
            guard textView.shouldChangeText(in: sourceRange, replacementString: formatted) else {
                return true
            }
            isFormatting = true
            textView.textStorage?.replaceCharacters(in: sourceRange, with: formatted)
            textView.didChangeText()
            isFormatting = false
            let formattedLength = (formatted as NSString).length
            textView.setSelectedRange(NSRange(location: min(caret, formattedLength), length: 0))
            textView.undoManager?.setActionName(parent.formatActionName)
            // Brief visual feedback for successful formatting.
            let originalColor = textView.insertionPointColor
            textView.insertionPointColor = NSColor(EditorTheme.success)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                textView.insertionPointColor = originalColor
            }
            return true
        } catch let error as TextFormatError {
            parent.onFormatError?(error.message)
            return true
        } catch {
            parent.onFormatError?("Unexpected token")
            return true
        }
    }

    /// Formats the SELECTED text only through
    /// the host's `formatSelectionHandler`; returns false when there is
    /// no handler or no selection (the key falls back to the
    /// whole-document handler).
    func applyFormatSelection(_ textView: NSTextView) -> Bool {
        guard textView.isEditable, let handler = parent.formatSelectionHandler else {
            return false
        }
        let selection = textView.selectedRange()
        guard selection.length > 0 else { return false }
        do {
            let selected = (textView.string as NSString).substring(with: selection)
            guard let formatted = try handler(selected) else { return true }
            guard textView.shouldChangeText(in: selection, replacementString: formatted) else {
                return true
            }
            isFormatting = true
            textView.textStorage?.replaceCharacters(in: selection, with: formatted)
            textView.didChangeText()
            isFormatting = false
            textView.setSelectedRange(
                NSRange(location: selection.location, length: (formatted as NSString).length))
            textView.undoManager?.setActionName(parent.formatActionName + " Selection")
            return true
        } catch let error as TextFormatError {
            parent.onFormatError?(error.message)
            return true
        } catch {
            parent.onFormatError?("Unexpected token")
            return true
        }
    }

    // MARK: Smart editing

    /// Per-language smart insertion: the effective opener table (Monaco
    /// `autoClosingBrackets`) and skip-over set derived from the active
    /// `SyntaxProfile`. `.never` disables both for the language,
    /// `.always` uses the historic global set, `.languageDefined` uses
    /// the profile's own `brackets`.
    private var effectiveOpeners: [Character: Character] {
        let pairs: [SyntaxProfile.BracketPair]
        switch parent.syntax.autoClosing {
        case .never: pairs = []
        case .always: pairs = SyntaxProfile.defaultBrackets
        case .languageDefined: pairs = parent.syntax.brackets
        }
        var out: [Character: Character] = [:]
        for pair in pairs { out[pair.open] = pair.close }
        return out
    }

    private var effectiveSkippers: Set<Character> {
        // `}` is always skipped over so a stray closing brace never traps
        // the caret, even though `{` itself never pairs (see default sets).
        var skippers = Set(effectiveOpeners.values)
        skippers.insert("}")
        return skippers
    }

    /// Backspace between an auto-paired empty pair deletes both
    /// characters (Monaco deleteLeft for matched pairs). Only pairs from
    /// the active table count - a stray closer never falls out of the
    /// document with its opener. Works on selection-free carets only.
    func deleteAutoPair(in textView: NSTextView) -> Bool {
        guard parent.enablesAutoPairing, !textView.hasMarkedText(),
            textView.isEditable
        else { return false }
        // Languages that opted out of pairing delete one char at a time.
        if parent.syntax.autoClosing == .never { return false }
        let openers = effectiveOpeners
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        let text = textView.string as NSString
        let caret = selection.location
        guard caret > 0, caret < text.length,
            let before = char(text, caret - 1),
            let after = char(text, caret),
            let closer = openers[before], closer == after
        else { return false }
        replace(
            in: textView,
            range: NSRange(location: caret - 1, length: 2),
            with: "",
            caret: caret - 1)
        return true
    }

    /// Bracket/quote smart insertion for a typed character. Consumes the
    /// keystroke (true) for skip-over, pairing, and selection wrap;
    /// anything else falls through to the standard insertion.
    func handleTypedCharacter(_ character: Character, in textView: NSTextView) -> Bool {
        guard parent.enablesAutoPairing else { return false }
        guard textView.isEditable, !textView.hasMarkedText() else { return false }
        // Languages that opted out never pair/skip.
        if parent.syntax.autoClosing == .never { return false }
        let openers = effectiveOpeners
        let skippers = effectiveSkippers
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let caret = selection.location

        // Skip-over: the matching character is already at the caret.
        if skippers.contains(character), caret < text.length,
            char(text, caret) == character
        {
            textView.setSelectedRange(NSRange(location: caret + 1, length: 0))
            return true
        }

        // Auto-outdent: a bracket closer typed into leading whitespace
        // pulls the line back one level (Monaco `autoIndent`). Skipped
        // when a selection replaces the text being typed over.
        let isAutoOutdentCloser = character == "}" || character == "]" || character == ")" || character == ">"
        if selection.length == 0, isAutoOutdentCloser {
            let lineRange = text.lineRange(for: NSRange(location: caret, length: 0))
            let lineStart = lineRange.location
            let prefix =
                caret > lineStart
                ? text.substring(with: NSRange(location: lineStart, length: caret - lineStart))
                : ""
            if !prefix.isEmpty, prefix.allSatisfy({ $0 == " " || $0 == "\t" }) {
                let indent = prefix
                let outdented: String
                if indent.hasPrefix("\t") {
                    outdented = String(indent.dropFirst())
                } else {
                    var trimmed = indent
                    var removed = 0
                    while removed < indentUnit.count, trimmed.hasPrefix(" ") {
                        trimmed = String(trimmed.dropFirst())
                        removed += 1
                    }
                    outdented = trimmed
                }
                if outdented != indent {
                    replace(
                        in: textView,
                        range: NSRange(location: lineStart, length: indent.count),
                        with: outdented + String(character),
                        caret: lineStart + outdented.count + 1)
                    return true
                }
            }
        }

        guard let closer = openers[character] else { return false }

        // Quotes never pair in the middle of a word (apostrophes: it's).
        if closer == character, caret > 0 {
            let previous = char(text, caret - 1)
            if let previous, previous.isLetter || previous.isNumber { return false }
        }

        let next = char(text, caret)
        let nextIsBoundary = next == nil || next?.isWhitespace == true || next.map(skippers.contains) == true

        if selection.length > 0 {
            // Surrounding (Monaco `autoSurround`): only the pair kinds the
            // language allows wrap the selection; otherwise fall through
            // to a plain replacement.
            let isQuote = closer == character
            switch parent.syntax.autoSurround {
            case .languageDefined: break
            case .quotes: guard isQuote else { return false }
            case .brackets: guard !isQuote else { return false }
            case .never: return false
            }
            let wrapped = text.substring(with: selection)
            replace(
                in: textView,
                range: selection,
                with: String(character) + wrapped + String(closer),
                caret: caret + (wrapped as NSString).length + 1)
            return true
        }
        if nextIsBoundary {
            replace(
                in: textView,
                range: NSRange(location: caret, length: 0),
                with: String(character) + String(closer),
                caret: caret + 1)
            return true
        }
        return false
    }

    /// Return: carries the current line's indentation; a fresh open brace
    /// before the caret expands to a blank indented line (and closes the
    /// pair when the matching closer sits ahead). Line-comment
    /// continuation and per-language `onEnterRules` (Monaco `onEnterRules`)
    /// extend the carried indent; both default off, so historic profiles
    /// keep the carry-only behavior.
    func insertNewlineWithIndent(_ textView: NSTextView) {
        guard textView.isEditable, !textView.hasMarkedText() else { return }
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let caret = selection.location
        let lineRange = text.lineRange(for: NSRange(location: caret, length: 0))
        let line = text.substring(with: lineRange)
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let previous = char(text, caret - 1)
        let next = char(text, caret)

        // Line-comment continuation (Monaco): a Return inside a line
        // comment starts the next line with the same prefix.
        if parent.syntax.continueLineComments,
            case let .line(prefix) = parent.syntax.commentStyle
        {
            let token = prefix.trimmingCharacters(in: .whitespaces)
            let beforeCaret = text.substring(
                with: NSRange(location: lineRange.location, length: max(caret - lineRange.location, 0)))
            let trimmedBefore = beforeCaret.trimmingCharacters(in: .whitespaces)
            if trimmedBefore.hasPrefix(token), !token.isEmpty {
                replace(
                    in: textView,
                    range: NSRange(location: caret, length: selection.length),
                    with: "\n" + indent + prefix,
                    caret: caret + 1 + (indent + prefix).count)
                return
            }
        }

        if let previous, let closer = effectiveOpeners[previous] {
            if next == closer {
                // Between a fresh pair: blank indented line between two
                // carried-indent lines, caret in the middle.
                replace(
                    in: textView,
                    range: NSRange(location: caret, length: selection.length),
                    with: "\n" + indent + indentUnit + "\n" + indent,
                    caret: caret + 1 + (indent + indentUnit).count)
            } else {
                replace(
                    in: textView,
                    range: NSRange(location: caret, length: selection.length),
                    with: "\n" + indent + indentUnit,
                    caret: caret + 1 + (indent + indentUnit).count)
            }
            return
        }
        // Per-language onEnterRules: the first pattern matching the line
        // prefix before the caret steers the new line's indent.
        for rule in parent.syntax.onEnterRules {
            let prefix = text.substring(
                with: NSRange(location: lineRange.location, length: max(caret - lineRange.location, 0)))
            guard
                let regex = try? NSRegularExpression(pattern: rule.pattern),
                regex.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) != nil
            else { continue }
            switch rule.action {
            case .none:
                replace(
                    in: textView,
                    range: NSRange(location: caret, length: selection.length),
                    with: "\n" + indent,
                    caret: caret + 1 + indent.count)
            case .indent:
                replace(
                    in: textView,
                    range: NSRange(location: caret, length: selection.length),
                    with: "\n" + indent + indentUnit,
                    caret: caret + 1 + (indent + indentUnit).count)
            case .outdent:
                let outdented: String
                if indent.hasPrefix("\t") {
                    outdented = String(indent.dropFirst())
                } else {
                    var trimmed = indent
                    var removed = 0
                    while removed < indentUnit.count, trimmed.hasPrefix(" ") {
                        trimmed = String(trimmed.dropFirst())
                        removed += 1
                    }
                    outdented = trimmed
                }
                replace(
                    in: textView,
                    range: NSRange(location: caret, length: selection.length),
                    with: "\n" + outdented,
                    caret: caret + 1 + outdented.count)
            }
            return
        }
        replace(
            in: textView,
            range: NSRange(location: caret, length: selection.length),
            with: "\n" + indent,
            caret: caret + 1 + indent.count)
    }

    /// Tab inserts the indent unit (or indents the selection's lines);
    /// Shift-Tab outdents the selection's lines by one unit.
    func indentSelection(_ textView: NSTextView, outdent: Bool) {
        guard textView.isEditable, !textView.hasMarkedText() else { return }
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let unit = indentUnit
        if !outdent, selection.length == 0 {
            replace(
                in: textView,
                range: NSRange(location: selection.location, length: 0),
                with: unit,
                caret: selection.location + unit.count)
            return
        }
        guard
            let selected = selectedBlock(text, selection: selection)
        else { return }

        var lines = selected.block.components(separatedBy: "\n")
        var deltaBeforeCaret = 0
        var consumed = 0
        for index in lines.indices {
            defer { consumed += lines[index].count + 1 }
            let isBlank = lines[index].trimmingCharacters(in: .whitespaces).isEmpty
            guard !isBlank else { continue }
            let before = lines[index]
            if outdent {
                if before.hasPrefix("\t") {
                    lines[index] = String(before.dropFirst())
                } else {
                    var removed = 0
                    while removed < unit.count, lines[index].hasPrefix(" ") {
                        lines[index] = String(lines[index].dropFirst())
                        removed += 1
                    }
                }
            } else {
                lines[index] = unit + lines[index]
            }
            if consumed <= selected.caretOffset {
                deltaBeforeCaret += lines[index].count - before.count
            }
        }
        let newBlock = lines.joined(separator: "\n")
        guard newBlock != selected.block else { return }
        if selection.length == 0 {
            replace(
                in: textView,
                range: selected.range,
                with: newBlock,
                caret: selection.location + deltaBeforeCaret)
        } else {
            // Keep the block selected, like every editor's Tab behavior.
            let newLength = (newBlock as NSString).length
            replace(
                in: textView,
                range: selected.range,
                with: newBlock,
                caret: selected.range.location)
            textView.setSelectedRange(
                NSRange(location: selected.range.location, length: newLength))
        }
    }

    /// ⌘/: comments per the profile's comment style (line for JavaScript,
    /// block for XML, nothing for JSON — no comments in the grammar, and
    /// hosts pick their own style for their own languages). Returns whether
    /// anything changed, so an unhandled key falls through.
    func toggleComment(_ textView: NSTextView) -> Bool {
        guard textView.isEditable, !textView.hasMarkedText() else { return false }
        switch parent.syntax.commentStyle {
        case .line(let prefix):
            return toggleLineComments(textView, prefix: prefix)
        case .block(let open, let close):
            return toggleBlockComment(textView, open: open, close: close)
        case .none:
            return false
        }
    }

    /// Line comments: comment when any selected line is uncommented,
    /// uncomment when every non-blank selected line already carries the
    /// comment token.
    private func toggleLineComments(_ textView: NSTextView, prefix: String) -> Bool {
        let token = prefix.trimmingCharacters(in: .whitespaces)
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        guard let selected = selectedBlock(text, selection: selection) else {
            return false
        }
        var lines = selected.block.components(separatedBy: "\n")
        var touched = false
        let allCommented = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix(token) }
        for index in lines.indices {
            guard !lines[index].trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let leading = lines[index].prefix { $0 == " " || $0 == "\t" }
            let body = lines[index].dropFirst(leading.count)
            if allCommented {
                var stripped = body
                if stripped.hasPrefix(token) { stripped = stripped.dropFirst(token.count) }
                if stripped.hasPrefix(" ") { stripped = stripped.dropFirst(1) }
                lines[index] = String(leading + stripped)
            } else {
                lines[index] = String(leading) + prefix + String(body)
            }
            touched = true
        }
        guard touched else { return false }
        let newBlock = lines.joined(separator: "\n")
        let newLength = (newBlock as NSString).length
        replace(
            in: textView,
            range: selected.range,
            with: newBlock,
            caret: selected.range.location)
        textView.setSelectedRange(
            NSRange(location: selected.range.location, length: newLength))
        return true
    }

    /// Block comments: wrap the selection (or the caret), or unwrap the
    /// comment surrounding the selection. Tokens come from the profile.
    func toggleBlockComment(_ textView: NSTextView, open openToken: String, close closeToken: String) -> Bool {
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let caret = min(selection.location, text.length)
        let before = text.substring(to: caret)
        let afterStart = min(NSMaxRange(selection), text.length)
        let after = text.substring(from: afterStart)

        // Uncomment when an opener before the selection pairs with a closer
        // after it (simple surrounding check; comments do not nest).
        let beforeText = before as NSString
        let afterText = after as NSString
        let open = beforeText.range(of: openToken, options: .backwards)
        let closeInAfter = afterText.range(of: closeToken)
        if open.location != NSNotFound, closeInAfter.location != NSNotFound,
            NSMaxRange(open) <= caret,
            afterStart + closeInAfter.location >= NSMaxRange(selection)
        {
            // Remove the closer first (higher offset): " -->" or "-->".
            var closeStart = afterStart + closeInAfter.location
            var closeLength = closeInAfter.length
            if closeStart > 0, char(text, closeStart - 1) == " " {
                closeStart -= 1
                closeLength += 1
            }
            replace(
                in: textView,
                range: NSRange(location: closeStart, length: closeLength),
                with: "",
                caret: caret)
            // Opener after the first replace (offsets below it hold).
            var openLength = open.length
            let currentText = textView.string as NSString
            if NSMaxRange(open) < currentText.length,
                char(currentText, NSMaxRange(open)) == " "
            {
                openLength += 1
            }
            replace(
                in: textView,
                range: NSRange(location: open.location, length: openLength),
                with: "",
                caret: max(caret - openLength, open.location))
            return true
        }

        // Wrap: selection in place, or an empty pair at the caret.
        if selection.length > 0 {
            let wrapped = text.substring(with: selection)
            replace(
                in: textView,
                range: selection,
                with: openToken + " " + wrapped + " " + closeToken,
                caret: selection.location + (wrapped as NSString).length + openToken.count + 1)
        } else {
            replace(
                in: textView,
                range: NSRange(location: caret, length: 0),
                with: openToken + "  " + closeToken,
                caret: caret + openToken.count + 1)
        }
        return true
    }

    // MARK: Shared edit plumbing

    /// The character at a UTF-16 offset, or nil when out of bounds.
    func char(_ text: NSString, _ offset: Int) -> Character? {
        guard offset >= 0, offset < text.length,
            let scalar = UnicodeScalar(text.character(at: offset))
        else { return nil }
        return Character(scalar)
    }

    /// A selected line block: its range (trailing newline excluded), the
    /// text, and the caret's offset within it - the shape every block
    /// transform (indent, outdent, comment toggle) consumes.
    struct SelectedBlock {
        let range: NSRange
        let block: String
        let caretOffset: Int
    }

    /// The line block covering the selection (or the caret's line), with
    /// its trailing newline excluded from the returned range.
    func selectedBlock(
        _ text: NSString,
        selection: NSRange
    ) -> SelectedBlock? {
        var end = selection.location + selection.length
        if selection.length > 0, end > selection.location,
            char(text, end - 1) == "\n"
        {
            end -= 1
        }
        var blockRange = text.lineRange(
            for: NSRange(location: selection.location, length: max(end - selection.location, 0)))
        if blockRange.length > 0,
            char(text, NSMaxRange(blockRange) - 1) == "\n"
        {
            blockRange.length -= 1
        }
        guard blockRange.length > 0 else { return nil }
        return SelectedBlock(
            range: blockRange,
            block: text.substring(with: blockRange),
            caretOffset: selection.location - blockRange.location)
    }

    /// One undoable replacement through the pipeline: registers the undo
    /// entry, funnels the edit through the text-storage delegate (paint +
    /// binding + height), and lands the caret where the caller says.
    @discardableResult
    func replace(
        in textView: NSTextView,
        range: NSRange,
        with replacement: String,
        caret: Int
    ) -> Bool {
        let length = (textView.string as NSString).length
        guard textView.isEditable, range.location >= 0, NSMaxRange(range) <= length else {
            return false
        }
        guard textView.shouldChangeText(in: range, replacementString: replacement) else {
            return false
        }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        let newLength = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(max(caret, 0), newLength), length: 0))
        return true
    }
}

extension NSRange {
    /// Clamped to `0...length` (a stray NSNotFound must never reach the
    /// storage). Nil when the range would be empty and out of bounds.
    fileprivate func clamped(to length: Int) -> NSRange? {
        guard location != NSNotFound else { return nil }
        let start = min(max(location, 0), length)
        let end = min(max(location + self.length, start), length)
        return NSRange(location: start, length: end - start)
    }
}
