import Foundation

@Observable
@MainActor
final class AppExternalNavigationCenter {
  struct SessionSelectionRequest: Equatable, Sendable, Identifiable {
    let id: UUID
    let sessionId: String
    let endpointId: UUID?
  }

  static let shared = AppExternalNavigationCenter()

  private(set) var pendingSelection: SessionSelectionRequest?
  private(set) var focusedWindowID: UUID?

  func submitSessionSelection(sessionId: String, endpointId: UUID?) {
    pendingSelection = SessionSelectionRequest(
      id: UUID(),
      sessionId: sessionId,
      endpointId: endpointId
    )
  }

  func updateFocusedWindow(_ windowID: UUID?) {
    focusedWindowID = windowID
  }

  func selection(for windowID: UUID) -> SessionSelectionRequest? {
    guard focusedWindowID == windowID else { return nil }
    return pendingSelection
  }

  func markHandled(_ requestID: UUID, by windowID: UUID) {
    guard focusedWindowID == windowID else { return }
    guard pendingSelection?.id == requestID else { return }
    pendingSelection = nil
  }
}
