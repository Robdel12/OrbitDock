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
    let dirty = ghostty.updateRenderState()
    guard dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE else { return }

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

    if style.bold != 0 || style.italic != 0 {
      var traits: CTFontSymbolicTraits = []
      if style.bold != 0 { traits.insert(.boldTrait) }
      if style.italic != 0 { traits.insert(.italicTrait) }
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
#endif
