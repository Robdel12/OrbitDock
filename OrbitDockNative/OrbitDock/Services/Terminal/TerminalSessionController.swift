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

  /// Called after PTY data has been fed into the terminal (for triggering view redraws).
  var onOutputReceived: (() -> Void)?

  /// Removes the server event listener on teardown.
  var removeListener: (() -> Void)?

  /// Called to notify the server of a resize.
  var sendResize: ((UInt16, UInt16) -> Void)?

  init(terminalId: String, cols: UInt16 = 80, rows: UInt16 = 24) {
    self.id = terminalId
    self.ghostty = GhosttyTerminalEmulator(cols: cols, rows: rows)
    self.keyEncoder = GhosttyKeyEncoderWrapper()

    // Wire up effects.
    ghostty.onWritePty = { [weak self] data in
      self?.sendToServer?(data)
    }

    ghostty.onTitleChanged = { [weak self] newTitle in
      self?.title = newTitle
    }
  }

  /// Feed raw PTY output bytes from the server into the terminal emulator.
  /// Dispatches to main queue to ensure ghostty's VT processing runs on
  /// the main thread's full 8MB stack (Swift async task stacks are ~512KB).
  func feedOutput(_ data: Data) {
    if Thread.isMainThread {
      ghostty.feedOutput(data)
      onOutputReceived?()
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.ghostty.feedOutput(data)
        self?.onOutputReceived?()
      }
    }
  }

  /// Encode and send keyboard input to the server.
  func sendKeyInput(_ data: Data) {
    sendToServer?(data)
  }

  /// Handle a resize: update the local terminal and notify the server.
  func handleResize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
    ghostty.resize(cols: cols, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
    sendResize?(cols, rows)
  }

  /// Mark the session as connected/disconnected.
  func setConnected(_ connected: Bool) {
    guard isConnected != connected else { return }
    isConnected = connected
  }
}
