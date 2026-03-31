import CoreGraphics

nonisolated struct ControlDeckFocusState: Equatable, Sendable {
  var isFocused = false
  var focusRequestSignal = 0
  var blurRequestSignal = 0
  var moveCursorToEndSignal = 0
  var measuredHeight: CGFloat = 30

  mutating func requestFocus() {
    focusRequestSignal &+= 1
  }

  mutating func moveCursorToEnd() {
    moveCursorToEndSignal &+= 1
  }
}
