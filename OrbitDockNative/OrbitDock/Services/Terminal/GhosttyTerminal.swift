import Foundation
import GhosttyVT

/// Swift wrapper around libghostty-vt's terminal emulator.
///
/// Manages the terminal state machine: feed VT data in, get render state out.
/// Thread safety: all methods must be called from the same actor/thread.
final class GhosttyTerminalEmulator {
  private(set) var terminal: GhosttyTerminal!
  private var renderState: GhosttyRenderState!
  private var rowIterator: GhosttyRenderStateRowIterator!
  private var rowCells: GhosttyRenderStateRowCells!

  /// Called when the terminal wants to write data back to the PTY
  /// (device status reports, mode queries, etc.)
  var onWritePty: ((Data) -> Void)?

  /// Called when the terminal title changes (OSC 0/2).
  var onTitleChanged: ((String) -> Void)?

  private(set) var cols: UInt16
  private(set) var rows: UInt16

  /// Set by the title_changed callback during vt_write; flushed after write completes.
  var titleDirty = false

  init(cols: UInt16 = 80, rows: UInt16 = 24, maxScrollback: Int = 10000) {
    self.cols = cols
    self.rows = rows

    let opts = GhosttyTerminalOptions(
      cols: cols,
      rows: rows,
      max_scrollback: maxScrollback
    )

    var term: GhosttyTerminal?
    let termResult = ghostty_terminal_new(nil, &term, opts)
    guard termResult == GHOSTTY_SUCCESS, let term else {
      fatalError("Failed to create ghostty terminal: \(termResult)")
    }
    self.terminal = term

    var rs: GhosttyRenderState?
    let rsResult = ghostty_render_state_new(nil, &rs)
    guard rsResult == GHOSTTY_SUCCESS, let rs else {
      fatalError("Failed to create ghostty render state: \(rsResult)")
    }
    self.renderState = rs

    var iter: GhosttyRenderStateRowIterator?
    let iterResult = ghostty_render_state_row_iterator_new(nil, &iter)
    guard iterResult == GHOSTTY_SUCCESS, let iter else {
      fatalError("Failed to create row iterator: \(iterResult)")
    }
    self.rowIterator = iter

    var cells: GhosttyRenderStateRowCells?
    let cellsResult = ghostty_render_state_row_cells_new(nil, &cells)
    guard cellsResult == GHOSTTY_SUCCESS, let cells else {
      fatalError("Failed to create row cells: \(cellsResult)")
    }
    self.rowCells = cells

    registerEffects()
  }

  deinit {
    ghostty_render_state_row_cells_free(rowCells)
    ghostty_render_state_row_iterator_free(rowIterator)
    ghostty_render_state_free(renderState)
    ghostty_terminal_free(terminal)
  }

  // MARK: - Effects Registration

  private func registerEffects() {
    let userdata = Unmanaged.passUnretained(self).toOpaque()
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, userdata)

    // write_pty — terminal needs to respond to queries
    let writePtyFn: GhosttyTerminalWritePtyFn = { terminal, userdata, data, len in
      guard let userdata, let data, len > 0 else { return }
      let wrapper = Unmanaged<GhosttyTerminalEmulator>.fromOpaque(userdata).takeUnretainedValue()
      let bytes = Data(bytes: data, count: len)
      wrapper.onWritePty?(bytes)
    }
    _ = withUnsafePointer(to: writePtyFn) { ptr in
      ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, ptr)
    }

    // Note: title_changed callback intentionally not registered.
    // ghostty's windowTitle handler overflows Swift async task stacks (~512KB).
    // Title is read on-demand via the `title` computed property instead.
  }

  // MARK: - Terminal I/O

  /// Feed raw VT-encoded bytes from the PTY into the terminal.
  func feedOutput(_ data: Data) {
    data.withUnsafeBytes { buffer in
      guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
      ghostty_terminal_vt_write(terminal, ptr, buffer.count)
    }

    // Read title only when the VT parser flagged a title change
    if titleDirty {
      titleDirty = false
      let currentTitle = title
      if !currentTitle.isEmpty {
        onTitleChanged?(currentTitle)
      }
    }
  }

  /// Resize the terminal grid.
  func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32 = 0, cellHeight: UInt32 = 0) {
    self.cols = cols
    self.rows = rows
    ghostty_terminal_resize(terminal, cols, rows, cellWidth, cellHeight)
  }

  /// Scroll the viewport by a delta (negative = up, positive = down).
  func scrollViewport(delta: Int) {
    var sv = GhosttyTerminalScrollViewport()
    sv.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
    sv.value.delta = delta
    ghostty_terminal_scroll_viewport(terminal, sv)
  }

  /// Scroll viewport to the bottom (active area).
  func scrollToBottom() {
    var sv = GhosttyTerminalScrollViewport()
    sv.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
    ghostty_terminal_scroll_viewport(terminal, sv)
  }

  // MARK: - Render State

  /// Update the render state from the current terminal state.
  /// Returns the dirty state indicating what needs to be redrawn.
  @discardableResult
  func updateRenderState() -> GhosttyRenderStateDirty {
    ghostty_render_state_update(renderState, terminal)

    var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
    ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
    return dirty
  }

  /// Get the current cursor state from the render state.
  func cursorState() -> CursorState {
    var visible = false
    ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible)

    var hasValue = false
    ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &hasValue)

    var x: UInt16 = 0
    var y: UInt16 = 0
    if hasValue {
      ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &x)
      ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &y)
    }

    var style = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK
    ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &style)

    var blinking = false
    ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, &blinking)

    return CursorState(
      visible: visible && hasValue,
      col: Int(x),
      row: Int(y),
      style: style,
      blinking: blinking
    )
  }

  /// Get the default foreground/background colors from the render state.
  func defaultColors() -> (fg: GhosttyColorRgb, bg: GhosttyColorRgb) {
    var fg = GhosttyColorRgb()
    var bg = GhosttyColorRgb()
    ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND, &fg)
    ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND, &bg)
    return (fg, bg)
  }

  /// Iterate all rows in the render state, calling the closure for each row.
  func forEachRow(_ body: (_ rowIndex: Int, _ isDirty: Bool, _ cells: RowCellIterator) -> Void) {
    ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator)

    var rowIndex = 0
    while ghostty_render_state_row_iterator_next(rowIterator) {
      var dirty = false
      ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &dirty)
      ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rowCells)

      let iterator = RowCellIterator(cells: rowCells)
      body(rowIndex, dirty, iterator)

      // Clear dirty flag after rendering.
      var cleanFlag = false
      ghostty_render_state_row_set(rowIterator, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &cleanFlag)

      rowIndex += 1
    }
  }

  /// Reset the global dirty state after rendering a full frame.
  func clearDirtyState() {
    var clean = GHOSTTY_RENDER_STATE_DIRTY_FALSE
    ghostty_render_state_set(renderState, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &clean)
  }

  // MARK: - Terminal Queries

  /// Get the current terminal title.
  var title: String {
    var titleStr = GhosttyString()
    let result = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &titleStr)
    guard result == GHOSTTY_SUCCESS, let ptr = titleStr.ptr, titleStr.len > 0 else { return "" }
    return String(bytes: UnsafeBufferPointer(start: ptr, count: titleStr.len), encoding: .utf8) ?? ""
  }

  /// Check if mouse tracking is active.
  var isMouseTrackingActive: Bool {
    var tracking = false
    ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
    return tracking
  }
}

// MARK: - Supporting Types

struct CursorState {
  let visible: Bool
  let col: Int
  let row: Int
  let style: GhosttyRenderStateCursorVisualStyle
  let blinking: Bool
}

/// Provides iteration over cells in a render state row.
struct RowCellIterator {
  let cells: GhosttyRenderStateRowCells!

  /// Advance to the next cell. Returns false when exhausted.
  func next() -> Bool {
    ghostty_render_state_row_cells_next(cells)
  }

  /// Get the grapheme string for the current cell.
  func grapheme() -> String {
    var len: UInt32 = 0
    ghostty_render_state_row_cells_get(
      cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &len
    )
    guard len > 0 else { return "" }

    var buf = [UInt32](repeating: 0, count: Int(len))
    ghostty_render_state_row_cells_get(
      cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &buf
    )

    // Fast path: single codepoint (covers ~99% of terminal cells)
    if len == 1, let scalar = Unicode.Scalar(buf[0]) {
      return String(scalar)
    }
    return buf.compactMap { Unicode.Scalar($0) }.map { String($0) }.joined()
  }

  /// Get the resolved foreground color for the current cell, or nil if default.
  func foregroundColor() -> GhosttyColorRgb? {
    var color = GhosttyColorRgb()
    let result = ghostty_render_state_row_cells_get(
      cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &color
    )
    return result == GHOSTTY_SUCCESS ? color : nil
  }

  /// Get the resolved background color for the current cell, or nil if default.
  func backgroundColor() -> GhosttyColorRgb? {
    var color = GhosttyColorRgb()
    let result = ghostty_render_state_row_cells_get(
      cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &color
    )
    return result == GHOSTTY_SUCCESS ? color : nil
  }

  /// Get the style flags for the current cell.
  func style() -> GhosttyStyle {
    var s = GhosttyStyle()
    ghostty_render_state_row_cells_get(
      cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &s
    )
    return s
  }
}
