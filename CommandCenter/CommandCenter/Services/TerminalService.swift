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
    /// Note: Claude Code TUI requires focus to receive keystroke events, so this
    /// briefly activates iTerm, sends the input, then returns focus to OrbitDock
    func sendInput(_ text: String, to session: Session, completion: ((Bool) -> Void)? = nil) {
        guard let terminalId = session.terminalSessionId, !terminalId.isEmpty,
              session.terminalApp == "iTerm.app" else {
            completion?(false)
            return
        }

        // Escape the text for AppleScript
        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // Claude Code's TUI uses raw terminal mode and only receives keystroke events
        // when iTerm is frontmost. We need to:
        // 1. Write the text to the session (works in background)
        // 2. Briefly activate iTerm to send the Return keystroke
        // 3. Return focus to OrbitDock
        let script = """
        -- First, write text without activating
        tell application "iTerm2"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        try
                            if "\(terminalId)" contains (unique ID of aSession) then
                                select aTab
                                select aSession
                                tell aSession to write text "\(escapedText)" newline NO

                                -- Activate iTerm to send keystroke
                                set index of aWindow to 1
                                activate
                                return "sent"
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            return "not_found"
        end tell
        """

        appleScript.execute(script) { [self] result in
            switch result {
            case .success(let output):
                if output == "sent" {
                    // Send keystroke Return (requires iTerm to be frontmost)
                    let returnScript = """
                    tell application "System Events"
                        tell process "iTerm2"
                            key code 36
                        end tell
                    end tell
                    -- Return focus to OrbitDock
                    tell application "OrbitDock" to activate
                    """
                    appleScript.execute(returnScript) { _ in
                        completion?(true)
                    }
                } else {
                    // Session not found - terminal may have been closed
                    completion?(false)
                }
            case .failure:
                completion?(false)
            }
        }
    }

    // MARK: - Private Implementation

    private func focusActiveSession(_ session: Session) {
        // First try by terminal session ID (most reliable)
        if let terminalId = session.terminalSessionId, !terminalId.isEmpty,
           session.terminalApp == "iTerm.app" {
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
        let script = """
        tell application "iTerm2"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        try
                            if "\(terminalId)" contains (unique ID of aSession) then
                                select aTab
                                select aSession
                                set index of aWindow to 1
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
            case .success(let output):
                completion(output?.hasPrefix("found") ?? false)
            case .failure:
                completion(false)
            }
        }
    }

    private func focusByPath(_ projectPath: String, completion: @escaping (Bool) -> Void) {
        let escapedPath = projectPath.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "iTerm2"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        try
                            set sessionPath to path of aSession
                            if sessionPath contains "\(escapedPath)" then
                                select aTab
                                select aSession
                                set index of aWindow to 1
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
            case .success(let output):
                completion(output == "found")
            case .failure(let error):
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
            if case .failure(let error) = result {
                print("TerminalService openNewTerminal error: \(error)")
            }
        }
    }
}
