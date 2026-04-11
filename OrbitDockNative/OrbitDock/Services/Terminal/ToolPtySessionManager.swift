import Foundation
import Observation

/// Manages tool PTY sessions for live streaming of bash command output.
///
/// This manager bridges tool PTY events from the server to Ghostty terminal sessions,
/// allowing tool cards to display live output from running commands.
@MainActor
@Observable
final class ToolPtySessionManager {
  private var sessions: [String: TerminalSessionController] = [:]
  private var attachedTools: Set<String> = []
  private var exitedTools: [String: Int32?] = [:]

  private func makeSession(toolId: String, cols: UInt16 = 80, rows: UInt16 = 24) -> TerminalSessionController {
    let session = TerminalSessionController(
      terminalId: "tool-pty-\(toolId)",
      cols: cols,
      rows: rows
    )
    // Tool PTY sessions are read-only - no input sent back to server
    session.sendToServer = nil
    return session
  }

  /// Get or create a terminal session for a tool.
  ///
  /// The session is created lazily and reused across attach/detach cycles
  /// until the tool completes and the session is cleaned up.
  func session(for toolId: String, cols: UInt16 = 80, rows: UInt16 = 24) -> TerminalSessionController {
    if let existing = sessions[toolId] {
      return existing
    }

    let session = makeSession(toolId: toolId, cols: cols, rows: rows)
    sessions[toolId] = session
    return session
  }

  /// Check if a tool has an active session.
  func hasSession(for toolId: String) -> Bool {
    sessions[toolId] != nil
  }

  /// Check if a tool is currently attached (subscribed to live output).
  func isAttached(_ toolId: String) -> Bool {
    attachedTools.contains(toolId)
  }

  /// Check if a tool has exited.
  func hasExited(_ toolId: String) -> Bool {
    exitedTools[toolId] != nil
  }

  /// Get the exit code for an exited tool.
  func exitCode(for toolId: String) -> Int32? {
    exitedTools[toolId] ?? nil
  }

  // MARK: - Server Event Handling

  /// Handle a tool PTY attached event from the server.
  func handleAttached(toolId: String, bufferedOutput: Data?) {
    attachedTools.insert(toolId)

    // Each attach includes the authoritative replay buffer from the server.
    // Rebuild the terminal session so reattaching a running tool never
    // appends the same historical output into an old emulator state.
    let session = makeSession(toolId: toolId)
    sessions[toolId] = session
    if let buffer = bufferedOutput, !buffer.isEmpty {
      session.feedOutput(buffer)
    }
  }

  /// Handle a tool PTY detached event from the server.
  func handleDetached(toolId: String) {
    attachedTools.remove(toolId)
  }

  /// Handle a tool PTY exited event from the server.
  func handleExited(toolId: String, exitCode: Int32?) {
    exitedTools[toolId] = exitCode
    attachedTools.remove(toolId)
  }

  /// Feed live output to a tool's terminal session.
  func feedOutput(toolId: String, data: Data) {
    guard let session = sessions[toolId] else { return }
    session.feedOutput(data)
  }

  // MARK: - Subscription Management

  /// Subscribe to live output for a tool.
  func attach(toolId: String, sessionId: String, connection: ServerConnection) {
    connection.subscribeToolPty(toolId: toolId, sessionId: sessionId)
  }

  /// Unsubscribe from live output for a tool.
  func detach(toolId: String, connection: ServerConnection) {
    connection.unsubscribeToolPty(toolId: toolId)
    attachedTools.remove(toolId)
  }

  // MARK: - Cleanup

  /// Clean up a tool's session after it's no longer needed.
  func cleanup(toolId: String) {
    sessions.removeValue(forKey: toolId)
    attachedTools.remove(toolId)
    exitedTools.removeValue(forKey: toolId)
  }

  /// Clean up all sessions for a given OrbitDock session.
  func cleanupForSession(_ sessionId: String) {
    // For now, clean up all sessions. In the future, we could track
    // which tools belong to which sessions.
    sessions.removeAll()
    attachedTools.removeAll()
    exitedTools.removeAll()
  }
}
