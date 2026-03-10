@testable import OrbitDock
import Foundation
import Testing

@MainActor
struct AppExternalNavigationCenterTests {
  @Test func focusedWindowReceivesPendingSelection() {
    let center = AppExternalNavigationCenter()
    let windowID = UUID()

    center.updateFocusedWindow(windowID)
    center.submitSessionSelection(sessionId: "session-123", endpointId: nil)

    let request = center.selection(for: windowID)

    #expect(request?.sessionId == "session-123")
    #expect(request?.endpointId == nil)
  }

  @Test func unfocusedWindowDoesNotReceiveSelection() {
    let center = AppExternalNavigationCenter()
    let focusedWindowID = UUID()
    let otherWindowID = UUID()

    center.updateFocusedWindow(focusedWindowID)
    center.submitSessionSelection(sessionId: "session-123", endpointId: nil)

    #expect(center.selection(for: otherWindowID) == nil)
    #expect(center.selection(for: focusedWindowID)?.sessionId == "session-123")
  }

  @Test func handledSelectionClearsPendingRequest() throws {
    let center = AppExternalNavigationCenter()
    let windowID = UUID()

    center.updateFocusedWindow(windowID)
    center.submitSessionSelection(sessionId: "session-123", endpointId: nil)
    let request = try #require(center.selection(for: windowID))

    center.markHandled(request.id, by: windowID)

    #expect(center.pendingSelection == nil)
  }

  @Test func pendingSelectionWaitsUntilWindowIsFocused() {
    let center = AppExternalNavigationCenter()
    let windowID = UUID()

    center.submitSessionSelection(sessionId: "session-123", endpointId: nil)
    #expect(center.selection(for: windowID) == nil)

    center.updateFocusedWindow(windowID)

    #expect(center.selection(for: windowID)?.sessionId == "session-123")
  }
}
