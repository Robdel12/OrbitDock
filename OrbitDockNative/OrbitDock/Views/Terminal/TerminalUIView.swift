#if os(iOS)
import UIKit
import CoreText
import GhosttyVT

/// UIView subclass that renders a terminal grid using Core Text.
///
/// iOS counterpart to TerminalNSView. Draws the terminal cell grid
/// in `draw(_:)` using Core Text for text and Core Graphics for
/// cell backgrounds and cursor.
final class TerminalUIView: UIView {
  // MARK: - Configuration

  weak var sessionController: TerminalSessionController?

  private let terminalFont: CTFont
  let cellWidth: CGFloat
  let cellHeight: CGFloat
  private let fontAscent: CGFloat

  private(set) var gridCols: UInt16 = 80
  private(set) var gridRows: UInt16 = 24

  var onResize: ((UInt16, UInt16) -> Void)?

  private var cursorBlinkTimer: Timer?
  private var cursorVisible = true

  // MARK: - Init

  init(font: UIFont? = nil) {
    let monoFont = font ?? UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    self.terminalFont = monoFont as CTFont

    let ascent = CTFontGetAscent(terminalFont)
    let descent = CTFontGetDescent(terminalFont)
    let leading = CTFontGetLeading(terminalFont)
    self.fontAscent = ascent
    self.cellHeight = ceil(ascent + descent + leading)

    var glyph = CTFontGetGlyphWithName(terminalFont, "W" as CFString)
    var advance = CGSize.zero
    CTFontGetAdvancesForGlyphs(terminalFont, .horizontal, &glyph, &advance, 1)
    self.cellWidth = ceil(advance.width)

    super.init(frame: .zero)
    backgroundColor = UIColor(red: 0.04, green: 0.04, blue: 0.052, alpha: 1.0)
    isOpaque = true
    clearsContextBeforeDrawing = false

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

  override var canBecomeFirstResponder: Bool { true }

  // On iOS, hardware keyboard input arrives via UIKeyCommand / pressesBegan.
  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    guard let controller = sessionController else {
      super.pressesBegan(presses, with: event)
      return
    }

    for press in presses {
      guard let key = press.key else { continue }
      let ghosttyKey = mapUIKeyCode(key.keyCode)
      let mods = mapUIKeyModifiers(key.modifierFlags)
      let text = key.characters.isEmpty ? nil : key.characters

      controller.keyEncoder.syncFromTerminal(controller.ghostty.terminal)
      if let encoded = controller.keyEncoder.encode(
        key: ghosttyKey,
        action: GHOSTTY_KEY_ACTION_PRESS,
        mods: mods,
        text: text
      ) {
        controller.sendKeyInput(encoded)
      }
    }
    cursorVisible = true
  }

  // MARK: - Layout → Grid Resize

  override func layoutSubviews() {
    super.layoutSubviews()

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

    // UIKit uses top-left origin like our flipped NSView.
    ghostty.forEachRow { rowIndex, _, cellIterator in
      let rowY = CGFloat(rowIndex) * cellHeight
      let rowRect = CGRect(x: 0, y: rowY, width: bounds.width, height: cellHeight)
      guard rowRect.intersects(rect) else { return }

      var colIndex = 0
      while cellIterator.next() {
        let cellX = CGFloat(colIndex) * cellWidth
        let cellRect = CGRect(x: cellX, y: rowY, width: cellWidth, height: cellHeight)

        if let bg = cellIterator.backgroundColor() {
          ctx.setFillColor(cgColor(from: bg))
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
      let cursorX = CGFloat(cursor.col) * cellWidth
      let cursorY = CGFloat(cursor.row) * cellHeight
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
    if blink && !cursorVisible { return }

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

private func cgColor(from c: GhosttyColorRgb) -> CGColor {
  CGColor(
    red: CGFloat(c.r) / 255.0,
    green: CGFloat(c.g) / 255.0,
    blue: CGFloat(c.b) / 255.0,
    alpha: 1.0
  )
}

// MARK: - iOS Key Mapping

private func mapUIKeyCode(_ code: UIKeyboardHIDUsage) -> GhosttyKey {
  switch code {
  case .keyboardA: return GHOSTTY_KEY_A
  case .keyboardB: return GHOSTTY_KEY_B
  case .keyboardC: return GHOSTTY_KEY_C
  case .keyboardD: return GHOSTTY_KEY_D
  case .keyboardE: return GHOSTTY_KEY_E
  case .keyboardF: return GHOSTTY_KEY_F
  case .keyboardG: return GHOSTTY_KEY_G
  case .keyboardH: return GHOSTTY_KEY_H
  case .keyboardI: return GHOSTTY_KEY_I
  case .keyboardJ: return GHOSTTY_KEY_J
  case .keyboardK: return GHOSTTY_KEY_K
  case .keyboardL: return GHOSTTY_KEY_L
  case .keyboardM: return GHOSTTY_KEY_M
  case .keyboardN: return GHOSTTY_KEY_N
  case .keyboardO: return GHOSTTY_KEY_O
  case .keyboardP: return GHOSTTY_KEY_P
  case .keyboardQ: return GHOSTTY_KEY_Q
  case .keyboardR: return GHOSTTY_KEY_R
  case .keyboardS: return GHOSTTY_KEY_S
  case .keyboardT: return GHOSTTY_KEY_T
  case .keyboardU: return GHOSTTY_KEY_U
  case .keyboardV: return GHOSTTY_KEY_V
  case .keyboardW: return GHOSTTY_KEY_W
  case .keyboardX: return GHOSTTY_KEY_X
  case .keyboardY: return GHOSTTY_KEY_Y
  case .keyboardZ: return GHOSTTY_KEY_Z
  case .keyboard1: return GHOSTTY_KEY_DIGIT_1
  case .keyboard2: return GHOSTTY_KEY_DIGIT_2
  case .keyboard3: return GHOSTTY_KEY_DIGIT_3
  case .keyboard4: return GHOSTTY_KEY_DIGIT_4
  case .keyboard5: return GHOSTTY_KEY_DIGIT_5
  case .keyboard6: return GHOSTTY_KEY_DIGIT_6
  case .keyboard7: return GHOSTTY_KEY_DIGIT_7
  case .keyboard8: return GHOSTTY_KEY_DIGIT_8
  case .keyboard9: return GHOSTTY_KEY_DIGIT_9
  case .keyboard0: return GHOSTTY_KEY_DIGIT_0
  case .keyboardReturnOrEnter: return GHOSTTY_KEY_ENTER
  case .keyboardEscape: return GHOSTTY_KEY_ESCAPE
  case .keyboardDeleteOrBackspace: return GHOSTTY_KEY_BACKSPACE
  case .keyboardTab: return GHOSTTY_KEY_TAB
  case .keyboardSpacebar: return GHOSTTY_KEY_SPACE
  case .keyboardHyphen: return GHOSTTY_KEY_MINUS
  case .keyboardEqualSign: return GHOSTTY_KEY_EQUAL
  case .keyboardOpenBracket: return GHOSTTY_KEY_BRACKET_LEFT
  case .keyboardCloseBracket: return GHOSTTY_KEY_BRACKET_RIGHT
  case .keyboardBackslash: return GHOSTTY_KEY_BACKSLASH
  case .keyboardSemicolon: return GHOSTTY_KEY_SEMICOLON
  case .keyboardQuote: return GHOSTTY_KEY_QUOTE
  case .keyboardGraveAccentAndTilde: return GHOSTTY_KEY_BACKQUOTE
  case .keyboardComma: return GHOSTTY_KEY_COMMA
  case .keyboardPeriod: return GHOSTTY_KEY_PERIOD
  case .keyboardSlash: return GHOSTTY_KEY_SLASH
  case .keyboardUpArrow: return GHOSTTY_KEY_ARROW_UP
  case .keyboardDownArrow: return GHOSTTY_KEY_ARROW_DOWN
  case .keyboardLeftArrow: return GHOSTTY_KEY_ARROW_LEFT
  case .keyboardRightArrow: return GHOSTTY_KEY_ARROW_RIGHT
  case .keyboardDeleteForward: return GHOSTTY_KEY_DELETE
  case .keyboardHome: return GHOSTTY_KEY_HOME
  case .keyboardEnd: return GHOSTTY_KEY_END
  case .keyboardPageUp: return GHOSTTY_KEY_PAGE_UP
  case .keyboardPageDown: return GHOSTTY_KEY_PAGE_DOWN
  case .keyboardF1: return GHOSTTY_KEY_F1
  case .keyboardF2: return GHOSTTY_KEY_F2
  case .keyboardF3: return GHOSTTY_KEY_F3
  case .keyboardF4: return GHOSTTY_KEY_F4
  case .keyboardF5: return GHOSTTY_KEY_F5
  case .keyboardF6: return GHOSTTY_KEY_F6
  case .keyboardF7: return GHOSTTY_KEY_F7
  case .keyboardF8: return GHOSTTY_KEY_F8
  case .keyboardF9: return GHOSTTY_KEY_F9
  case .keyboardF10: return GHOSTTY_KEY_F10
  case .keyboardF11: return GHOSTTY_KEY_F11
  case .keyboardF12: return GHOSTTY_KEY_F12
  default: return GHOSTTY_KEY_UNIDENTIFIED
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
