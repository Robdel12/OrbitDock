import Foundation
import Observation

/// Coordinates a single interactive terminal session.
///
/// Bridges the server-side PTY (via WebSocket) with the client-side
/// libghostty-vt terminal emulator for rendering and input encoding.
@Observable
final class TerminalSessionController: Identifiable {
  let id: String
  let ghostty: GhosttyTerminalEmulator
  let keyEncoder: GhosttyKeyEncoderWrapper

  private(set) var title: String = "Terminal"
  private(set) var isConnected = false

  /// Closure to send encoded input bytes to the server.
  var sendToServer: ((Data) -> Void)?

  init(terminalId: String, cols: UInt16 = 80, rows: UInt16 = 24) {
    self.id = terminalId
    self.ghostty = GhosttyTerminalEmulator(cols: cols, rows: rows)
    self.keyEncoder = GhosttyKeyEncoderWrapper()

    // Wire up effects.
    ghostty.onWritePty = { [weak self] data in
      // VT query responses need to go back to the server's PTY.
      self?.sendToServer?(data)
    }

    ghostty.onTitleChanged = { [weak self] newTitle in
      self?.title = newTitle
    }
  }

  /// Feed raw PTY output bytes from the server into the terminal emulator.
  func feedOutput(_ data: Data) {
    ghostty.feedOutput(data)
  }

  /// Encode and send keyboard input to the server.
  func sendKeyInput(_ data: Data) {
    sendToServer?(data)
  }

  /// Handle a resize: update the local terminal and notify the server.
  func handleResize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
    ghostty.resize(cols: cols, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
  }

  /// Mark the session as connected/disconnected.
  func setConnected(_ connected: Bool) {
    isConnected = connected
  }
}
