#if os(iOS)
  import CoreText
  import GhosttyVT
  import UIKit

  /// UIView subclass that renders a terminal grid using Core Text.
  ///
  /// iOS counterpart to TerminalNSView. Draws the terminal cell grid
  /// in `draw(_:)` using Core Text for text and Core Graphics for
  /// cell backgrounds and cursor.
  ///
  /// Conforms to `UIKeyInput` so the iOS software keyboard appears when
  /// this view becomes first responder. Hardware keyboard events still
  /// arrive through `pressesBegan`.
  final class TerminalUIView: UIView, UIKeyInput {
    // MARK: - Configuration

    weak var sessionController: TerminalSessionController?

    private static let defaultFontSize: CGFloat = 12
    private static let minFontSize: CGFloat = 7
    private static let maxFontSize: CGFloat = 24

    private(set) var currentFontSize: CGFloat = TerminalUIView.defaultFontSize
    private(set) var terminalFont: CTFont
    private(set) var cellWidth: CGFloat
    private(set) var cellHeight: CGFloat
    private(set) var fontAscent: CGFloat

    /// Content insets — breathing room between the terminal grid and view edges.
    let contentInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

    private(set) var gridCols: UInt16 = 80
    private(set) var gridRows: UInt16 = 24

    var onResize: ((UInt16, UInt16) -> Void)?

    private var cursorBlinkTimer: Timer?
    private var cursorVisible = true
    var shouldAutoFocusOnFirstAttachment = false
    private var hasAutoFocusedOnAttachment = false

    /// Modifier state toggled by the accessory bar (Ctrl, Alt).
    /// Applied to the next key event, then auto-cleared.
    var pendingModifiers: GhosttyMods = 0

    /// Pinch-to-zoom baseline font size at gesture start.
    private var pinchBaseFontSize: CGFloat = 0

    /// Text selection state — (col, row) cell coordinates.
    private var selectionStart: (col: Int, row: Int)?
    private var selectionEnd: (col: Int, row: Int)?
    private var isSelecting = false

    /// Cached haptic generators to avoid per-use allocation.
    private let selectionFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let lightFeedback = UIImpactFeedbackGenerator(style: .light)
    private let notificationFeedback = UINotificationFeedbackGenerator()

    private lazy var _accessoryBar: TerminalAccessoryBar = .init(terminalView: self)

    // MARK: - Init

    init(font: UIFont? = nil) {
      let size = font.map { CTFontGetSize($0 as CTFont) } ?? Self.defaultFontSize
      let monoFont = font ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
      let ctFont = monoFont as CTFont

      let metrics = Self.fontMetrics(for: ctFont)
      self.currentFontSize = size
      self.terminalFont = ctFont
      self.fontAscent = metrics.ascent
      self.cellHeight = metrics.cellHeight
      self.cellWidth = metrics.cellWidth

      super.init(frame: .zero)
      backgroundColor = UIColor(red: 0.04, green: 0.04, blue: 0.052, alpha: 1.0)
      isOpaque = true
      clearsContextBeforeDrawing = false

      setupScrollGesture()
      setupZoomGestures()
      setupSelectionGesture()
      startCursorBlink()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    deinit {
      cursorBlinkTimer?.invalidate()
    }

    // MARK: - First Responder & Keyboard

    override var canBecomeFirstResponder: Bool {
      true
    }

    @discardableResult
    func requestFocus() -> Bool {
      guard window != nil else { return false }
      return becomeFirstResponder()
    }

    @discardableResult
    func requestInitialFocusIfNeeded() -> Bool {
      guard shouldAutoFocusOnFirstAttachment, !hasAutoFocusedOnAttachment else { return false }
      let didFocus = requestFocus()
      if didFocus {
        hasAutoFocusedOnAttachment = true
      }
      return didFocus
    }

    override var inputAccessoryView: UIView? {
      _accessoryBar
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()

      guard window != nil else { return }
      DispatchQueue.main.async { [weak self] in
        _ = self?.requestInitialFocusIfNeeded()
      }
    }

    // UIKeyInput — software keyboard support

    var hasText: Bool {
      true
    }

    func insertText(_ text: String) {
      guard sessionController != nil else { return }
      if selectionStart != nil { clearSelection() }

      for char in text {
        let ghosttyKey = mapCharacterToGhosttyKey(char)
        let mods = consumePendingModifiers()
        encodeAndSend(key: ghosttyKey, mods: mods, text: String(char))
      }
    }

    func deleteBackward() {
      guard sessionController != nil else { return }
      encodeAndSend(key: GHOSTTY_KEY_BACKSPACE, mods: consumePendingModifiers(), text: nil)
    }

    // UITextInputTraits — dark keyboard, no autocorrect

    override var textInputContextIdentifier: String? {
      "terminal"
    }

    var keyboardAppearance: UIKeyboardAppearance = .dark
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    // MARK: - Special Key Input (from accessory bar)

    /// Send a special key event (Esc, Tab, arrows, etc.) from the accessory bar.
    func sendSpecialKey(_ key: GhosttyKey, text: String? = nil) {
      encodeAndSend(key: key, mods: consumePendingModifiers(), text: text)
    }

    /// Encode a key event via ghostty and send it to the server.
    private func encodeAndSend(key: GhosttyKey, mods: GhosttyMods, text: String?) {
      guard let controller = sessionController else { return }
      controller.keyEncoder.syncFromTerminal(controller.ghostty.terminal)
      if let encoded = controller.keyEncoder.encode(
        key: key,
        action: GHOSTTY_KEY_ACTION_PRESS,
        mods: mods,
        text: text
      ) {
        controller.sendKeyInput(encoded)
      }
      cursorVisible = true
      setNeedsDisplay()
    }

    /// Consume pending modifiers and reset them.
    private func consumePendingModifiers() -> GhosttyMods {
      let mods = pendingModifiers
      pendingModifiers = 0
      _accessoryBar.clearModifiers()
      return mods
    }

    /// On iOS, hardware keyboard input arrives via UIKeyCommand / pressesBegan.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      guard sessionController != nil else {
        super.pressesBegan(presses, with: event)
        return
      }

      for press in presses {
        guard let key = press.key else { continue }
        let ghosttyKey = mapUIKeyCode(key.keyCode)
        let mods = mapUIKeyModifiers(key.modifierFlags)
        let text = key.characters.isEmpty ? nil : key.characters
        encodeAndSend(key: ghosttyKey, mods: mods, text: text)
      }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
      _ = requestFocus()
      super.touchesBegan(touches, with: event)
    }

    // MARK: - Layout → Grid Resize

    override func layoutSubviews() {
      super.layoutSubviews()

      let usableWidth = bounds.width - contentInsets.left - contentInsets.right
      let usableHeight = bounds.height - contentInsets.top - contentInsets.bottom
      let newCols = max(1, UInt16(usableWidth / cellWidth))
      let newRows = max(1, UInt16(usableHeight / cellHeight))

      if newCols != gridCols || newRows != gridRows {
        gridCols = newCols
        gridRows = newRows
        onResize?(newCols, newRows)
        // Redraw immediately — the grid changed (e.g. keyboard appeared/dismissed)
        // and the terminal needs to repaint at the new dimensions.
        setNeedsDisplay()
      }
    }

    // MARK: - Scroll (pan gesture → scrollback)

    /// Accumulated fractional scroll distance (converted to row deltas).
    private var scrollAccumulator: CGFloat = 0

    private func setupScrollGesture() {
      let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePanScroll(_:)))
      // Two-finger only — one-finger drag is reserved for text selection (long press).
      pan.minimumNumberOfTouches = 2
      pan.maximumNumberOfTouches = 2
      addGestureRecognizer(pan)
    }

    @objc private func handlePanScroll(_ gesture: UIPanGestureRecognizer) {
      guard let controller = sessionController else { return }

      switch gesture.state {
        case .changed:
          let translation = gesture.translation(in: self)
          // Invert: dragging up (negative translation) scrolls back (negative delta = up)
          scrollAccumulator += -translation.y
          let rowDelta = Int(scrollAccumulator / cellHeight)
          if rowDelta != 0 {
            controller.ghostty.scrollViewport(delta: rowDelta)
            scrollAccumulator -= CGFloat(rowDelta) * cellHeight
            setNeedsDisplay()
          }
          gesture.setTranslation(.zero, in: self)

        case .ended, .cancelled:
          scrollAccumulator = 0

        default:
          break
      }
    }

    // MARK: - Pinch-to-Zoom & Double-Tap Reset

    private func setupZoomGestures() {
      let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinchZoom(_:)))
      addGestureRecognizer(pinch)

      let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTapReset(_:)))
      doubleTap.numberOfTapsRequired = 2
      addGestureRecognizer(doubleTap)
    }

    @objc private func handlePinchZoom(_ gesture: UIPinchGestureRecognizer) {
      switch gesture.state {
        case .began:
          pinchBaseFontSize = currentFontSize

        case .changed:
          let newSize = min(Self.maxFontSize, max(Self.minFontSize, pinchBaseFontSize * gesture.scale))
          // Only rebuild if the rounded size actually changed (avoid thrashing)
          let rounded = (newSize * 2).rounded() / 2 // snap to 0.5pt increments
          if rounded != currentFontSize {
            updateFont(size: rounded)
          }

        default:
          break
      }
    }

    @objc private func handleDoubleTapReset(_ gesture: UITapGestureRecognizer) {
      guard currentFontSize != Self.defaultFontSize else { return }
      updateFont(size: Self.defaultFontSize)
      lightFeedback.impactOccurred()
    }

    /// Rebuild font metrics and trigger a full grid recalculation + redraw.
    private func updateFont(size: CGFloat) {
      let monoFont = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
      let ctFont = monoFont as CTFont
      let metrics = Self.fontMetrics(for: ctFont)

      currentFontSize = size
      terminalFont = ctFont
      fontAscent = metrics.ascent
      cellHeight = metrics.cellHeight
      cellWidth = metrics.cellWidth

      // Force grid recalculation at the new cell dimensions
      gridCols = 0
      gridRows = 0
      setNeedsLayout()
      layoutIfNeeded()
    }

    /// Calculate font metrics from a CTFont — shared between init and updateFont.
    private static func fontMetrics(for ctFont: CTFont) -> (ascent: CGFloat, cellHeight: CGFloat, cellWidth: CGFloat) {
      let ascent = CTFontGetAscent(ctFont)
      let height = ceil(ascent + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont))
      var glyph = CTFontGetGlyphWithName(ctFont, "W" as CFString)
      var advance = CGSize.zero
      CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
      return (ascent, height, ceil(advance.width))
    }

    // MARK: - Text Selection

    private func setupSelectionGesture() {
      let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPressSelection(_:)))
      longPress.minimumPressDuration = 0.3
      addGestureRecognizer(longPress)
    }

    @objc private func handleLongPressSelection(_ gesture: UILongPressGestureRecognizer) {
      let point = gesture.location(in: self)
      let cell = cellAt(point: point)

      switch gesture.state {
        case .began:
          isSelecting = true
          selectionStart = cell
          selectionEnd = cell
          selectionFeedback.impactOccurred()
          setNeedsDisplay()

        case .changed:
          selectionEnd = cell
          setNeedsDisplay()

        case .ended:
          selectionEnd = cell
          isSelecting = false
          setNeedsDisplay()
          showCopyMenu(at: point)

        case .cancelled, .failed:
          clearSelection()

        default:
          break
      }
    }

    /// Convert a point in view coordinates to a (col, row) cell coordinate.
    private func cellAt(point: CGPoint) -> (col: Int, row: Int) {
      let col = max(0, Int((point.x - contentInsets.left) / cellWidth))
      let row = max(0, Int((point.y - contentInsets.top) / cellHeight))
      return (col: min(col, Int(gridCols) - 1), row: min(row, Int(gridRows) - 1))
    }

    /// Normalize selection so start is before end in reading order.
    private func normalizedSelection() -> (start: (col: Int, row: Int), end: (col: Int, row: Int))? {
      guard let start = selectionStart, let end = selectionEnd else { return nil }
      if start.row < end.row || (start.row == end.row && start.col <= end.col) {
        return (start, end)
      }
      return (end, start)
    }

    /// Whether a cell at (col, row) falls within a pre-normalized selection range.
    private static func cellInSelection(col: Int, row: Int, s: (col: Int, row: Int), e: (col: Int, row: Int)) -> Bool {
      if row < s.row || row > e.row { return false }
      if row == s.row, row == e.row { return col >= s.col && col <= e.col }
      if row == s.row { return col >= s.col }
      if row == e.row { return col <= e.col }
      return true
    }

    /// Extract selected text from the ghostty render state.
    private func selectedText() -> String? {
      guard let sel = normalizedSelection(),
            let controller = sessionController else { return nil }

      let ghostty = controller.ghostty
      ghostty.updateRenderState()

      var lines: [String] = []
      ghostty.forEachRow { rowIndex, _, cellIterator in
        guard rowIndex >= sel.start.row, rowIndex <= sel.end.row else { return }

        var rowText = ""
        var colIndex = 0
        while cellIterator.next() {
          if Self.cellInSelection(col: colIndex, row: rowIndex, s: sel.start, e: sel.end) {
            let grapheme = cellIterator.grapheme()
            rowText += grapheme.isEmpty ? " " : grapheme
          }
          colIndex += 1
        }
        lines.append(rowText)
      }

      let result = lines
        .map { String($0.reversed().drop(while: { $0 == " " }).reversed()) }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return result.isEmpty ? nil : result
    }

    private func showCopyMenu(at point: CGPoint) {
      guard selectionStart != nil else { return }
      becomeFirstResponder()
      let menu = UIMenuController.shared
      menu.showMenu(from: self, rect: CGRect(origin: point, size: CGSize(width: 1, height: 1)))
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
      if action == #selector(copy(_:)) {
        return selectionStart != nil
      }
      if action == #selector(paste(_:)) {
        return UIPasteboard.general.hasStrings
      }
      return super.canPerformAction(action, withSender: sender)
    }

    override func copy(_ sender: Any?) {
      guard let text = selectedText() else { return }
      UIPasteboard.general.string = text
      notificationFeedback.notificationOccurred(.success)
      clearSelection()
    }

    override func paste(_ sender: Any?) {
      guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
      clearSelection()
      insertText(text)
    }

    func clearSelection() {
      selectionStart = nil
      selectionEnd = nil
      isSelecting = false
      setNeedsDisplay()
      UIMenuController.shared.hideMenu()
    }

    // MARK: - Cursor Blink

    private func startCursorBlink() {
      cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
        guard let self else { return }
        self.cursorVisible.toggle()
        self.setNeedsDisplay()
      }
    }

    func terminalDidUpdate() {
      setNeedsDisplay()
      cursorVisible = true
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
      guard let ctx = UIGraphicsGetCurrentContext(),
            let controller = sessionController else { return }

      let ghostty = controller.ghostty
      ghostty.updateRenderState()

      let (defaultFg, defaultBg) = ghostty.defaultColors()
      let bgColor = cgColor(from: defaultBg)

      ctx.setFillColor(bgColor)
      ctx.fill(bounds)

      let originX = contentInsets.left
      let originY = contentInsets.top
      let sel = normalizedSelection()
      let selHighlight = CGColor(red: 0.33, green: 0.68, blue: 0.90, alpha: 0.30)

      // UIKit uses top-left origin like our flipped NSView.
      ghostty.forEachRow { rowIndex, _, cellIterator in
        let rowY = originY + CGFloat(rowIndex) * cellHeight
        let rowRect = CGRect(x: originX, y: rowY, width: bounds.width - originX, height: cellHeight)
        guard rowRect.intersects(rect) else { return }

        var colIndex = 0
        while cellIterator.next() {
          let cellX = originX + CGFloat(colIndex) * cellWidth
          let cellRect = CGRect(x: cellX, y: rowY, width: cellWidth, height: cellHeight)

          if let bg = cellIterator.backgroundColor() {
            ctx.setFillColor(cgColor(from: bg))
            ctx.fill(cellRect)
          }

          if let sel, Self.cellInSelection(col: colIndex, row: rowIndex, s: sel.start, e: sel.end) {
            ctx.setFillColor(selHighlight)
            ctx.fill(cellRect)
          }

          let grapheme = cellIterator.grapheme()
          if !grapheme.isEmpty {
            let fg = cellIterator.foregroundColor() ?? defaultFg
            let style = cellIterator.style()
            drawText(ctx: ctx, text: grapheme, at: cellRect, color: fg, style: style)
          }

          colIndex += 1
        }
      }

      let cursor = ghostty.cursorState()
      if cursor.visible {
        let cursorX = originX + CGFloat(cursor.col) * cellWidth
        let cursorY = originY + CGFloat(cursor.row) * cellHeight
        let cursorRect = CGRect(x: cursorX, y: cursorY, width: cellWidth, height: cellHeight)
        drawCursor(ctx: ctx, rect: cursorRect, style: cursor.style, blink: cursor.blinking)
      }

      ghostty.clearDirtyState()
    }

    private func drawText(ctx: CGContext, text: String, at rect: CGRect, color: GhosttyColorRgb, style: GhosttyStyle) {
      let fgColor = cgColor(from: color)
      var font = terminalFont

      if style.bold || style.italic {
        var traits: CTFontSymbolicTraits = []
        if style.bold { traits.insert(.boldTrait) }
        if style.italic { traits.insert(.italicTrait) }
        if let styledFont = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, traits, traits) {
          font = styledFont
        }
      }

      let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: UIColor(cgColor: fgColor),
      ]
      let attrStr = NSAttributedString(string: text, attributes: attrs)
      let line = CTLineCreateWithAttributedString(attrStr)

      // Core Text draws with bottom-left origin. In UIKit's top-left coordinate system,
      // we need to flip the context for text drawing.
      ctx.saveGState()
      ctx.translateBy(x: rect.origin.x, y: rect.origin.y + cellHeight)
      ctx.scaleBy(x: 1, y: -1)
      ctx.textPosition = CGPoint(x: 0, y: cellHeight - fontAscent)
      CTLineDraw(line, ctx)
      ctx.restoreGState()
    }

    private func drawCursor(ctx: CGContext, rect: CGRect, style: GhosttyRenderStateCursorVisualStyle, blink: Bool) {
      if blink, !cursorVisible { return }

      let cursorColor = CGColor(red: 0.35, green: 0.85, blue: 0.55, alpha: 1.0)

      switch style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK:
          ctx.setFillColor(cursorColor.copy(alpha: 0.6)!)
          ctx.fill(rect)

        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
          let barRect = CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height)
          ctx.setFillColor(cursorColor)
          ctx.fill(barRect)

        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
          let underRect = CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2)
          ctx.setFillColor(cursorColor)
          ctx.fill(underRect)

        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
          ctx.setStrokeColor(cursorColor)
          ctx.setLineWidth(1)
          ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))

        default:
          break
      }
    }
  }

  // MARK: - Character → GhosttyKey Mapping

  /// Map a printable character to the corresponding GhosttyKey.
  /// The encoder uses the text parameter for actual byte generation,
  /// so the key mapping mostly needs to identify the base key.
  private func mapCharacterToGhosttyKey(_ char: Character) -> GhosttyKey {
    let lower = char.lowercased()
    switch lower {
      case "a": return GHOSTTY_KEY_A
      case "b": return GHOSTTY_KEY_B
      case "c": return GHOSTTY_KEY_C
      case "d": return GHOSTTY_KEY_D
      case "e": return GHOSTTY_KEY_E
      case "f": return GHOSTTY_KEY_F
      case "g": return GHOSTTY_KEY_G
      case "h": return GHOSTTY_KEY_H
      case "i": return GHOSTTY_KEY_I
      case "j": return GHOSTTY_KEY_J
      case "k": return GHOSTTY_KEY_K
      case "l": return GHOSTTY_KEY_L
      case "m": return GHOSTTY_KEY_M
      case "n": return GHOSTTY_KEY_N
      case "o": return GHOSTTY_KEY_O
      case "p": return GHOSTTY_KEY_P
      case "q": return GHOSTTY_KEY_Q
      case "r": return GHOSTTY_KEY_R
      case "s": return GHOSTTY_KEY_S
      case "t": return GHOSTTY_KEY_T
      case "u": return GHOSTTY_KEY_U
      case "v": return GHOSTTY_KEY_V
      case "w": return GHOSTTY_KEY_W
      case "x": return GHOSTTY_KEY_X
      case "y": return GHOSTTY_KEY_Y
      case "z": return GHOSTTY_KEY_Z
      case "0": return GHOSTTY_KEY_DIGIT_0
      case "1": return GHOSTTY_KEY_DIGIT_1
      case "2": return GHOSTTY_KEY_DIGIT_2
      case "3": return GHOSTTY_KEY_DIGIT_3
      case "4": return GHOSTTY_KEY_DIGIT_4
      case "5": return GHOSTTY_KEY_DIGIT_5
      case "6": return GHOSTTY_KEY_DIGIT_6
      case "7": return GHOSTTY_KEY_DIGIT_7
      case "8": return GHOSTTY_KEY_DIGIT_8
      case "9": return GHOSTTY_KEY_DIGIT_9
      case " ": return GHOSTTY_KEY_SPACE
      case "\n", "\r": return GHOSTTY_KEY_ENTER
      case "\t": return GHOSTTY_KEY_TAB
      case "-": return GHOSTTY_KEY_MINUS
      case "=": return GHOSTTY_KEY_EQUAL
      case "[": return GHOSTTY_KEY_BRACKET_LEFT
      case "]": return GHOSTTY_KEY_BRACKET_RIGHT
      case "\\": return GHOSTTY_KEY_BACKSLASH
      case ";": return GHOSTTY_KEY_SEMICOLON
      case "'": return GHOSTTY_KEY_QUOTE
      case "`": return GHOSTTY_KEY_BACKQUOTE
      case ",": return GHOSTTY_KEY_COMMA
      case ".": return GHOSTTY_KEY_PERIOD
      case "/": return GHOSTTY_KEY_SLASH
      // Shifted variants map to their base key
      case "!": return GHOSTTY_KEY_DIGIT_1
      case "@": return GHOSTTY_KEY_DIGIT_2
      case "#": return GHOSTTY_KEY_DIGIT_3
      case "$": return GHOSTTY_KEY_DIGIT_4
      case "%": return GHOSTTY_KEY_DIGIT_5
      case "^": return GHOSTTY_KEY_DIGIT_6
      case "&": return GHOSTTY_KEY_DIGIT_7
      case "*": return GHOSTTY_KEY_DIGIT_8
      case "(": return GHOSTTY_KEY_DIGIT_9
      case ")": return GHOSTTY_KEY_DIGIT_0
      case "_": return GHOSTTY_KEY_MINUS
      case "+": return GHOSTTY_KEY_EQUAL
      case "{": return GHOSTTY_KEY_BRACKET_LEFT
      case "}": return GHOSTTY_KEY_BRACKET_RIGHT
      case "|": return GHOSTTY_KEY_BACKSLASH
      case ":": return GHOSTTY_KEY_SEMICOLON
      case "\"": return GHOSTTY_KEY_QUOTE
      case "~": return GHOSTTY_KEY_BACKQUOTE
      case "<": return GHOSTTY_KEY_COMMA
      case ">": return GHOSTTY_KEY_PERIOD
      case "?": return GHOSTTY_KEY_SLASH
      default: return GHOSTTY_KEY_UNIDENTIFIED
    }
  }

  private func cgColor(from c: GhosttyColorRgb) -> CGColor {
    CGColor(
      red: CGFloat(c.r) / 255.0,
      green: CGFloat(c.g) / 255.0,
      blue: CGFloat(c.b) / 255.0,
      alpha: 1.0
    )
  }

  // MARK: - iOS Key Mapping (hardware keyboard)

  private func mapUIKeyCode(_ code: UIKeyboardHIDUsage) -> GhosttyKey {
    switch code {
      case .keyboardA: GHOSTTY_KEY_A
      case .keyboardB: GHOSTTY_KEY_B
      case .keyboardC: GHOSTTY_KEY_C
      case .keyboardD: GHOSTTY_KEY_D
      case .keyboardE: GHOSTTY_KEY_E
      case .keyboardF: GHOSTTY_KEY_F
      case .keyboardG: GHOSTTY_KEY_G
      case .keyboardH: GHOSTTY_KEY_H
      case .keyboardI: GHOSTTY_KEY_I
      case .keyboardJ: GHOSTTY_KEY_J
      case .keyboardK: GHOSTTY_KEY_K
      case .keyboardL: GHOSTTY_KEY_L
      case .keyboardM: GHOSTTY_KEY_M
      case .keyboardN: GHOSTTY_KEY_N
      case .keyboardO: GHOSTTY_KEY_O
      case .keyboardP: GHOSTTY_KEY_P
      case .keyboardQ: GHOSTTY_KEY_Q
      case .keyboardR: GHOSTTY_KEY_R
      case .keyboardS: GHOSTTY_KEY_S
      case .keyboardT: GHOSTTY_KEY_T
      case .keyboardU: GHOSTTY_KEY_U
      case .keyboardV: GHOSTTY_KEY_V
      case .keyboardW: GHOSTTY_KEY_W
      case .keyboardX: GHOSTTY_KEY_X
      case .keyboardY: GHOSTTY_KEY_Y
      case .keyboardZ: GHOSTTY_KEY_Z
      case .keyboard1: GHOSTTY_KEY_DIGIT_1
      case .keyboard2: GHOSTTY_KEY_DIGIT_2
      case .keyboard3: GHOSTTY_KEY_DIGIT_3
      case .keyboard4: GHOSTTY_KEY_DIGIT_4
      case .keyboard5: GHOSTTY_KEY_DIGIT_5
      case .keyboard6: GHOSTTY_KEY_DIGIT_6
      case .keyboard7: GHOSTTY_KEY_DIGIT_7
      case .keyboard8: GHOSTTY_KEY_DIGIT_8
      case .keyboard9: GHOSTTY_KEY_DIGIT_9
      case .keyboard0: GHOSTTY_KEY_DIGIT_0
      case .keyboardReturnOrEnter: GHOSTTY_KEY_ENTER
      case .keyboardEscape: GHOSTTY_KEY_ESCAPE
      case .keyboardDeleteOrBackspace: GHOSTTY_KEY_BACKSPACE
      case .keyboardTab: GHOSTTY_KEY_TAB
      case .keyboardSpacebar: GHOSTTY_KEY_SPACE
      case .keyboardHyphen: GHOSTTY_KEY_MINUS
      case .keyboardEqualSign: GHOSTTY_KEY_EQUAL
      case .keyboardOpenBracket: GHOSTTY_KEY_BRACKET_LEFT
      case .keyboardCloseBracket: GHOSTTY_KEY_BRACKET_RIGHT
      case .keyboardBackslash: GHOSTTY_KEY_BACKSLASH
      case .keyboardSemicolon: GHOSTTY_KEY_SEMICOLON
      case .keyboardQuote: GHOSTTY_KEY_QUOTE
      case .keyboardGraveAccentAndTilde: GHOSTTY_KEY_BACKQUOTE
      case .keyboardComma: GHOSTTY_KEY_COMMA
      case .keyboardPeriod: GHOSTTY_KEY_PERIOD
      case .keyboardSlash: GHOSTTY_KEY_SLASH
      case .keyboardUpArrow: GHOSTTY_KEY_ARROW_UP
      case .keyboardDownArrow: GHOSTTY_KEY_ARROW_DOWN
      case .keyboardLeftArrow: GHOSTTY_KEY_ARROW_LEFT
      case .keyboardRightArrow: GHOSTTY_KEY_ARROW_RIGHT
      case .keyboardDeleteForward: GHOSTTY_KEY_DELETE
      case .keyboardHome: GHOSTTY_KEY_HOME
      case .keyboardEnd: GHOSTTY_KEY_END
      case .keyboardPageUp: GHOSTTY_KEY_PAGE_UP
      case .keyboardPageDown: GHOSTTY_KEY_PAGE_DOWN
      case .keyboardF1: GHOSTTY_KEY_F1
      case .keyboardF2: GHOSTTY_KEY_F2
      case .keyboardF3: GHOSTTY_KEY_F3
      case .keyboardF4: GHOSTTY_KEY_F4
      case .keyboardF5: GHOSTTY_KEY_F5
      case .keyboardF6: GHOSTTY_KEY_F6
      case .keyboardF7: GHOSTTY_KEY_F7
      case .keyboardF8: GHOSTTY_KEY_F8
      case .keyboardF9: GHOSTTY_KEY_F9
      case .keyboardF10: GHOSTTY_KEY_F10
      case .keyboardF11: GHOSTTY_KEY_F11
      case .keyboardF12: GHOSTTY_KEY_F12
      default: GHOSTTY_KEY_UNIDENTIFIED
    }
  }

  private func mapUIKeyModifiers(_ flags: UIKeyModifierFlags) -> GhosttyMods {
    var mods: GhosttyMods = 0
    if flags.contains(.shift) { mods |= UInt16(GHOSTTY_MODS_SHIFT) }
    if flags.contains(.control) { mods |= UInt16(GHOSTTY_MODS_CTRL) }
    if flags.contains(.alternate) { mods |= UInt16(GHOSTTY_MODS_ALT) }
    if flags.contains(.command) { mods |= UInt16(GHOSTTY_MODS_SUPER) }
    if flags.contains(.alphaShift) { mods |= UInt16(GHOSTTY_MODS_CAPS_LOCK) }
    return mods
  }
#endif
