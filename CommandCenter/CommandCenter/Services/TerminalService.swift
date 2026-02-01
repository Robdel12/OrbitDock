//
//  TerminalService.swift
//  OrbitDock
//
//  iTerm2 integration service - uses AppleScriptService for execution
//

import Foundation

@MainActor
final class TerminalService {
  static let shared = TerminalService()

  private let appleScript = AppleScriptService.shared

  private init() {}

  // MARK: - Public API

  /// Focus an existing terminal session or open a new one with resume command
  func focusSession(_ session: Session) {
    if session.isActive {
      focusActiveSession(session)
    } else {
      openNewTerminalWithResume(session)
    }
  }

  /// Send text input to a terminal session
  /// Claude's TUI requires keystroke events, so we activate iTerm and send Return
  func sendInput(_ text: String, to session: Session, completion: ((Bool) -> Void)? = nil) {
    guard let terminalId = session.terminalSessionId, !terminalId.isEmpty,
          session.terminalApp == "iTerm.app"
    else {
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
    tell application "iTerm2"
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
        case .failure:
          completion?(false)
      }
    }
  }

  // MARK: - Private Implementation

  private func focusActiveSession(_ session: Session) {
    // First try by terminal session ID (most reliable)
    if let terminalId = session.terminalSessionId, !terminalId.isEmpty,
       session.terminalApp == "iTerm.app"
    {
      focusBySessionId(terminalId) { [weak self] found in
        if !found {
          // Fallback to path-based matching
          self?.focusByPath(session.projectPath) { found in
            if !found {
              print("TerminalService: Could not find terminal for session \(session.id)")
            }
          }
        }
      }
    } else {
      // No terminal ID, try path-based matching
      focusByPath(session.projectPath) { found in
        if !found {
          print("TerminalService: Could not find terminal by path for session \(session.id)")
        }
      }
    }
  }

  private func focusBySessionId(_ terminalId: String, completion: @escaping (Bool) -> Void) {
    // terminalId format from hooks: "w9t1p0:UUID" - iTerm only knows the UUID part
    // Use explicit indexing to avoid reference issues when reordering windows
    let script = """
    tell application "iTerm2"
        repeat with winIdx from 1 to count of windows
            set aWindow to window winIdx
            repeat with tabIdx from 1 to count of tabs of aWindow
                set aTab to tab tabIdx of aWindow
                repeat with aSession in sessions of aTab
                    try
                        if "\(terminalId)" contains (unique ID of aSession) then
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

    appleScript.execute(script) { result in
      switch result {
        case let .success(output):
          completion(output?.hasPrefix("found") ?? false)
        case .failure:
          completion(false)
      }
    }
  }

  private func focusByPath(_ projectPath: String, completion: @escaping (Bool) -> Void) {
    let escapedPath = projectPath.replacingOccurrences(of: "\"", with: "\\\"")

    // Use explicit indexing to avoid reference issues when reordering windows
    let script = """
    tell application "iTerm2"
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

    appleScript.execute(script) { result in
      switch result {
        case let .success(output):
          completion(output == "found")
        case let .failure(error):
          print("TerminalService focusByPath error: \(error)")
          completion(false)
      }
    }
  }

  private func openNewTerminalWithResume(_ session: Session) {
    let escapedPath = session.projectPath.replacingOccurrences(of: "'", with: "'\\''")
    let command = "cd '\(escapedPath)' && claude --resume \(session.id)"

    let script = """
    tell application "iTerm2"
        activate
        set newWindow to (create window with default profile)
        tell current session of newWindow
            write text "\(command)"
        end tell
    end tell
    """

    appleScript.execute(script) { result in
      if case let .failure(error) = result {
        print("TerminalService openNewTerminal error: \(error)")
      }
    }
  }
}
