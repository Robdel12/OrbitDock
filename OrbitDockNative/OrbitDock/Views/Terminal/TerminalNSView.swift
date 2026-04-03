#if os(macOS)
  import AppKit
  import CoreText
  import GhosttyVT

  /// NSView subclass that renders a terminal grid using Core Text.
  ///
  /// Draws the terminal cell grid directly in `draw(_:)` using Core Text for
  /// text and Core Graphics for cell backgrounds and cursor. Rendering is
  /// driven by `setNeedsDisplay()` calls when new PTY data arrives.
  final class TerminalNSView: NSView {
    // MARK: - Configuration

    weak var sessionController: TerminalSessionController?

    /// The monospace font used for terminal rendering.
    private let terminalFont: CTFont
    /// Computed cell dimensions from font metrics.
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    /// Font ascent for baseline positioning.
    private let fontAscent: CGFloat

    /// Current grid dimensions (updated on layout).
    private(set) var gridCols: UInt16 = 80
    private(set) var gridRows: UInt16 = 24

    /// Called when the grid dimensions change (for server resize notification).
    var onResize: ((UInt16, UInt16) -> Void)?

    // MARK: - Cursor Blink

    private var cursorBlinkTimer: Timer?
    private var cursorVisible = true
    var shouldAutoFocusOnFirstAttachment = false
    /// When false, wheel events are ignored unless this view is focused.
    var captureScrollWithoutFocus = true
    private var hasAutoFocusedOnAttachment = false
    /// Accumulates high-resolution wheel deltas so trackpad scroll isn't lost.
    private var scrollAccumulator: CGFloat = 0

    // MARK: - Init

    init(font: NSFont? = nil) {
      let monoFont = font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
      self.terminalFont = monoFont as CTFont

      // Measure cell dimensions from the font.
      let ascent = CTFontGetAscent(terminalFont)
      let descent = CTFontGetDescent(terminalFont)
      let leading = CTFontGetLeading(terminalFont)
      self.fontAscent = ascent
      self.cellHeight = ceil(ascent + descent + leading)

      // Use the advance width of "W" as the cell width (monospace font).
      var glyph = CTFontGetGlyphWithName(terminalFont, "W" as CFString)
      var advance = CGSize.zero
      CTFontGetAdvancesForGlyphs(terminalFont, .horizontal, &glyph, &advance, 1)
      self.cellWidth = ceil(advance.width)

      super.init(frame: .zero)
      wantsLayer = true
      layer?.backgroundColor = NSColor(red: 0.04, green: 0.04, blue: 0.052, alpha: 1.0).cgColor

      startCursorBlink()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    deinit {
      cursorBlinkTimer?.invalidate()
    }

    // MARK: - First Responder (keyboard input)

    override var acceptsFirstResponder: Bool {
      true
    }

    func requestFocus() {
      guard let window else { return }
      window.makeFirstResponder(self)
    }

    func requestInitialFocusIfNeeded() {
      guard shouldAutoFocusOnFirstAttachment, !hasAutoFocusedOnAttachment, window != nil else { return }
      hasAutoFocusedOnAttachment = true
      requestFocus()
    }

    override func becomeFirstResponder() -> Bool {
      cursorVisible = true
      needsDisplay = true
      return true
    }

    override func resignFirstResponder() -> Bool {
      needsDisplay = true
      return true
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()

      guard window != nil else { return }
      DispatchQueue.main.async { [weak self] in
        self?.requestInitialFocusIfNeeded()
      }
    }

    // MARK: - Layout → Grid Resize

    override func layout() {
      super.layout()

      let newCols = max(1, UInt16(bounds.width / cellWidth))
      let newRows = max(1, UInt16(bounds.height / cellHeight))

      if newCols != gridCols || newRows != gridRows {
        gridCols = newCols
        gridRows = newRows
        onResize?(newCols, newRows)
      }
    }

    // MARK: - Cursor Blink

    private func startCursorBlink() {
      cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
        guard let self else { return }
        self.cursorVisible.toggle()
        self.needsDisplay = true
      }
    }

    // MARK: - Trigger Redraw

    /// Call this when new PTY data has been fed into the terminal.
    func terminalDidUpdate() {
      needsDisplay = true
      cursorVisible = true
    }

    // MARK: - Drawing

    override var isFlipped: Bool {
      true
    }

    override func draw(_ dirtyRect: NSRect) {
      guard let ctx = NSGraphicsContext.current?.cgContext,
            let controller = sessionController else { return }

      let ghostty = controller.ghostty
      ghostty.updateRenderState()

      let (defaultFg, defaultBg) = ghostty.defaultColors()
      let bgColor = cgColor(from: defaultBg)
      let isFocused = window?.firstResponder === self

      // Draw background.
      ctx.setFillColor(bgColor)
      ctx.fill(bounds)

      // Iterate rows and cells.
      ghostty.forEachRow { rowIndex, _, cellIterator in
        let rowY = CGFloat(rowIndex) * cellHeight

        // Skip rows outside dirty rect.
        let rowRect = CGRect(x: 0, y: rowY, width: bounds.width, height: cellHeight)
        guard rowRect.intersects(dirtyRect) else { return }

        var colIndex = 0
        while cellIterator.next() {
          let cellX = CGFloat(colIndex) * cellWidth
          let cellRect = CGRect(x: cellX, y: rowY, width: cellWidth, height: cellHeight)

          // Cell background.
          if let bg = cellIterator.backgroundColor() {
            ctx.setFillColor(cgColor(from: bg))
            ctx.fill(cellRect)
          }

          // Cell text.
          let grapheme = cellIterator.grapheme()
          if !grapheme.isEmpty {
            let fg = cellIterator.foregroundColor() ?? defaultFg
            let style = cellIterator.style()
            drawText(ctx: ctx, text: grapheme, at: cellRect, color: fg, style: style)
          }

          colIndex += 1
        }
      }

      // Draw cursor.
      let cursor = ghostty.cursorState()
      if cursor.visible {
        let cursorX = CGFloat(cursor.col) * cellWidth
        let cursorY = CGFloat(cursor.row) * cellHeight
        let cursorRect = CGRect(x: cursorX, y: cursorY, width: cellWidth, height: cellHeight)

        drawCursor(ctx: ctx, rect: cursorRect, style: cursor.style, focused: isFocused, blink: cursor.blinking)
      }

      ghostty.clearDirtyState()
    }

    // MARK: - Text Drawing

    private func drawText(ctx: CGContext, text: String, at rect: CGRect, color: GhosttyColorRgb, style: GhosttyStyle) {
      let fgColor = cgColor(from: color)
      var font = terminalFont

      // Apply bold/italic if needed.
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
        .foregroundColor: NSColor(cgColor: fgColor) ?? NSColor.white,
      ]
      let attrStr = NSAttributedString(string: text, attributes: attrs)
      let line = CTLineCreateWithAttributedString(attrStr)

      // In a flipped NSView, Core Text's text matrix must counter the CTM flip.
      ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
      ctx.textPosition = CGPoint(x: rect.origin.x, y: rect.origin.y + fontAscent)
      CTLineDraw(line, ctx)

      // Underline.
      if style.underline != 0 {
        let underlineY = rect.maxY - 1
        ctx.setStrokeColor(fgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: rect.minX, y: underlineY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: underlineY))
        ctx.strokePath()
      }

      // Strikethrough.
      if style.strikethrough {
        let strikeY = rect.midY
        ctx.setStrokeColor(fgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: rect.minX, y: strikeY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: strikeY))
        ctx.strokePath()
      }
    }

    // MARK: - Cursor Drawing

    private func drawCursor(
      ctx: CGContext,
      rect: CGRect,
      style: GhosttyRenderStateCursorVisualStyle,
      focused: Bool,
      blink: Bool
    ) {
      // If blinking and currently invisible, skip.
      if blink, !cursorVisible { return }

      let cursorColor = CGColor(red: 0.35, green: 0.85, blue: 0.55, alpha: 1.0) // terminal green

      switch style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK:
          if focused {
            ctx.setFillColor(cursorColor.copy(alpha: 0.6)!)
            ctx.fill(rect)
          } else {
            // Hollow block when unfocused.
            ctx.setStrokeColor(cursorColor)
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
          }

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

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
      guard let controller = sessionController else { return }

      controller.keyEncoder.syncFromTerminal(controller.ghostty.terminal)

      if let encoded = controller.keyEncoder.encode(nsEvent: event) {
        controller.sendKeyInput(encoded)
      }

      cursorVisible = true
    }

    override func flagsChanged(with event: NSEvent) {
      // Modifier-only events: don't send to terminal (no output).
    }

    override func mouseDown(with event: NSEvent) {
      requestFocus()
      super.mouseDown(with: event)
    }

    // MARK: - Scroll

    override func scrollWheel(with event: NSEvent) {
      guard let controller = sessionController else { return }
      let isFocused = window?.firstResponder === self
      if !captureScrollWithoutFocus, !isFocused {
        super.scrollWheel(with: event)
        return
      }

      // Trackpads emit sub-line deltas; convert to row movement using cell height.
      let deltaY: CGFloat
      if event.hasPreciseScrollingDeltas {
        deltaY = event.scrollingDeltaY
      } else {
        // Mouse wheels are line-ish units. Scale by row height for consistent feel.
        deltaY = event.scrollingDeltaY * cellHeight
      }

      scrollAccumulator += -deltaY
      let rowDelta = Int(scrollAccumulator / cellHeight)
      if rowDelta != 0 {
        controller.ghostty.scrollViewport(delta: rowDelta)
        scrollAccumulator -= CGFloat(rowDelta) * cellHeight
        needsDisplay = true
      }

      if event.phase == .ended || event.phase == .cancelled
        || event.momentumPhase == .ended || event.momentumPhase == .cancelled
      {
        scrollAccumulator = 0
      }
    }
  }

  // MARK: - Color Conversion

  private func cgColor(from c: GhosttyColorRgb) -> CGColor {
    CGColor(
      red: CGFloat(c.r) / 255.0,
      green: CGFloat(c.g) / 255.0,
      blue: CGFloat(c.b) / 255.0,
      alpha: 1.0
    )
  }
#endif
