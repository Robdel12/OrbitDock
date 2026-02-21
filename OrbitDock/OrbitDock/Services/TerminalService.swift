//
//  TerminalService.swift
//  OrbitDock
//
//  iTerm2 integration service - uses AppleScriptService for execution
//

import Foundation
import OSLog

@MainActor
final class TerminalService {
  static let shared = TerminalService()

  private let appleScript = AppleScriptService.shared
  private let iTermApplicationReference = "application id \"com.googlecode.iterm2\""
  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OrbitDock", category: "terminal-service")

  private init() {}

  // MARK: - Public API

  /// Focus an existing terminal session or open a new one with resume command.
  /// Returns `true` if the terminal was found/opened successfully.
  func focusSession(_ session: Session) async -> Bool {
    if session.isActive {
      await focusActiveSession(session)
    } else {
      await openNewTerminalWithResume(session)
    }
  }

  /// Send text input to a terminal session
  /// Claude's TUI requires keystroke events, so we activate iTerm and send Return
  func sendInput(_ text: String, to session: Session, completion: ((Bool) -> Void)? = nil) {
    guard let terminalId = session.terminalSessionId, !terminalId.isEmpty,
          isITermSession(session.terminalApp)
    else {
      logger
        .error(
          "sendInput skipped unsupported terminal app session=\(session.id, privacy: .public) terminalApp=\(session.terminalApp ?? "nil", privacy: .public)"
        )
      completion?(false)
      return
    }

    // Escape the text for AppleScript
    let escapedText = text
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")

    // Write text, activate iTerm, send Return - user stays in iTerm to watch Claude
    // Use explicit indexing to avoid reference issues when reordering windows
    let script = """
    tell \(iTermApplicationReference)
        repeat with winIdx from 1 to count of windows
            set aWindow to window winIdx
            repeat with tabIdx from 1 to count of tabs of aWindow
                set aTab to tab tabIdx of aWindow
                repeat with aSession in sessions of aTab
                    try
                        if "\(terminalId)" contains (unique ID of aSession) then
                            -- Write the text (no newline yet)
                            tell aSession to write text "\(escapedText)" newline false
                            -- Bring window to front first
                            set index of aWindow to 1
                            -- Select the tab
                            select aTab
                            -- Select session (for split panes)
                            select aSession
                            activate
                            -- Send Return keystroke
                            tell application "System Events" to key code 36
                            return "sent"
                        end if
                    end try
                end repeat
            end repeat
        end repeat
        return "not_found"
    end tell
    """

    appleScript.execute(script) { result in
      switch result {
        case let .success(output):
          completion?(output == "sent")
        case let .failure(error):
          self.logger
            .error(
              "sendInput AppleScript failed session=\(session.id, privacy: .public) terminalId=\(terminalId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
          completion?(false)
      }
    }
  }

  // MARK: - Private Implementation

  private func focusActiveSession(_ session: Session) async -> Bool {
    logger
      .info(
        "focus requested session=\(session.id, privacy: .public) terminalApp=\(session.terminalApp ?? "nil", privacy: .public) terminalId=\(session.terminalSessionId ?? "nil", privacy: .public)"
      )

    // First try by terminal session ID (most reliable)
    if let terminalId = session.terminalSessionId, !terminalId.isEmpty,
       isITermSession(session.terminalApp)
    {
      let found = await focusBySessionId(terminalId)
      if found { return true }

      // Fallback to path-based matching
      let foundByPath = await focusByPath(session.projectPath)
      if !foundByPath {
        logger
          .error("focus failed for session=\(session.id, privacy: .public) reason=not_found_by_id_or_path")
      }
      return foundByPath
    } else {
      // No terminal ID, try path-based matching
      let found = await focusByPath(session.projectPath)
      if !found {
        logger
          .error("focus failed for session=\(session.id, privacy: .public) reason=not_found_by_path_no_terminal_id")
      }
      return found
    }
  }

  private func focusBySessionId(_ terminalId: String) async -> Bool {
    // terminalId format from hooks: "w9t1p0:UUID" - iTerm only knows the UUID part
    let terminalUUID = extractTerminalUUID(from: terminalId)
    let escapedTerminalId = terminalId.replacingOccurrences(of: "\"", with: "\\\"")
    let escapedTerminalUUID = terminalUUID.replacingOccurrences(of: "\"", with: "\\\"")

    // Use explicit indexing to avoid reference issues when reordering windows
    let script = """
    tell \(iTermApplicationReference)
        repeat with winIdx from 1 to count of windows
            set aWindow to window winIdx
            repeat with tabIdx from 1 to count of tabs of aWindow
                set aTab to tab tabIdx of aWindow
                repeat with aSession in sessions of aTab
                    try
                        if (unique ID of aSession) is "\(escapedTerminalUUID)" or "\(
                          escapedTerminalId
                        )" contains (unique ID of aSession) then
                            -- Bring window to front first
                            set index of aWindow to 1
                            -- Select the tab
                            select aTab
                            -- Select session (for split panes)
                            select aSession
                            activate
                            return "found"
                        end if
                    end try
                end repeat
            end repeat
        end repeat
        return "not_found"
    end tell
    """

    do {
      let output = try await appleScript.execute(script)
      return output?.hasPrefix("found") ?? false
    } catch {
      logger
        .error(
          "focusBySessionId AppleScript failed terminalId=\(terminalId, privacy: .public) terminalUUID=\(terminalUUID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
      return false
    }
  }

  private func focusByPath(_ projectPath: String) async -> Bool {
    let escapedPath = projectPath.replacingOccurrences(of: "\"", with: "\\\"")

    // Use explicit indexing to avoid reference issues when reordering windows
    let script = """
    tell \(iTermApplicationReference)
        repeat with winIdx from 1 to count of windows
            set aWindow to window winIdx
            repeat with tabIdx from 1 to count of tabs of aWindow
                set aTab to tab tabIdx of aWindow
                repeat with aSession in sessions of aTab
                    try
                        set sessionPath to path of aSession
                        if sessionPath contains "\(escapedPath)" then
                            -- Bring window to front first
                            set index of aWindow to 1
                            -- Select the tab
                            select aTab
                            -- Select session (for split panes)
                            select aSession
                            activate
                            return "found"
                        end if
                    end try
                end repeat
            end repeat
        end repeat
        return "not_found"
    end tell
    """

    do {
      let output = try await appleScript.execute(script)
      return output == "found"
    } catch {
      logger
        .error(
          "focusByPath AppleScript failed path=\(projectPath, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
      return false
    }
  }

  private func openNewTerminalWithResume(_ session: Session) async -> Bool {
    let escapedPath = session.projectPath.replacingOccurrences(of: "'", with: "'\\''")
    let command = "cd '\(escapedPath)' && claude --resume \(session.id)"

    let script = """
    tell \(iTermApplicationReference)
        activate
        set newWindow to (create window with default profile)
        tell current session of newWindow
            write text "\(command)"
        end tell
    end tell
    """

    do {
      _ = try await appleScript.execute(script)
      return true
    } catch {
      logger
        .error(
          "openNewTerminal AppleScript failed session=\(session.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
      return false
    }
  }

  private func isITermSession(_ terminalApp: String?) -> Bool {
    guard let terminalApp else { return false }
    return terminalApp == "iTerm.app" || terminalApp == "iTerm2" || terminalApp == "iTerm"
  }

  private func extractTerminalUUID(from terminalId: String) -> String {
    guard let uuid = terminalId.split(separator: ":").last, !uuid.isEmpty else {
      return terminalId
    }
    return String(uuid)
  }
}
