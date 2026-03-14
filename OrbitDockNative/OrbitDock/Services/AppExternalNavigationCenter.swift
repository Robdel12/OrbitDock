import Foundation

enum AppExternalCommand: Equatable, Sendable {
  case selectSession(sessionId: String, endpointId: UUID?)
}

@MainActor
final class AppExternalNavigationCenter {
  typealias CommandHandler = @MainActor (AppExternalCommand) -> Void

  private(set) var focusedWindowID: UUID?
  private var pendingCommand: AppExternalCommand?
  private var handlers: [UUID: CommandHandler] = [:]

  func registerWindow(_ windowID: UUID, handler: @escaping CommandHandler) {
    handlers[windowID] = handler
    dispatchPendingCommandIfPossible()
  }

  func unregisterWindow(_ windowID: UUID) {
    handlers.removeValue(forKey: windowID)
    if focusedWindowID == windowID {
      focusedWindowID = nil
    }
  }

  func updateFocusedWindow(_ windowID: UUID?) {
    focusedWindowID = windowID
    dispatchPendingCommandIfPossible()
  }

  func submitSessionSelection(sessionId: String, endpointId: UUID?) {
    submit(.selectSession(sessionId: sessionId, endpointId: endpointId))
  }

  func submit(_ command: AppExternalCommand) {
    pendingCommand = command
    dispatchPendingCommandIfPossible()
  }

  private func dispatchPendingCommandIfPossible() {
    guard let focusedWindowID, let pendingCommand, let handler = handlers[focusedWindowID] else {
      return
    }

    self.pendingCommand = nil
    handler(pendingCommand)
  }
}
