@testable import OrbitDock
import Foundation
import Testing

@MainActor
struct AppExternalNavigationCenterTests {
  @Test func focusedWindowReceivesCommandImmediately() {
    let center = AppExternalNavigationCenter()
    let windowID = UUID()
    var received: [AppExternalCommand] = []

    center.registerWindow(windowID) { command in
      received.append(command)
    }
    center.updateFocusedWindow(windowID)

    center.submitSessionSelection(sessionId: "session-123", endpointId: nil)

    #expect(received == [.selectSession(sessionId: "session-123", endpointId: nil)])
  }

  @Test func unfocusedWindowDoesNotReceiveCommand() {
    let center = AppExternalNavigationCenter()
    let focusedWindowID = UUID()
    let otherWindowID = UUID()
    var focusedReceived: [AppExternalCommand] = []
    var otherReceived: [AppExternalCommand] = []

    center.registerWindow(focusedWindowID) { command in
      focusedReceived.append(command)
    }
    center.registerWindow(otherWindowID) { command in
      otherReceived.append(command)
    }
    center.updateFocusedWindow(focusedWindowID)

    center.submitSessionSelection(sessionId: "session-123", endpointId: nil)

    #expect(focusedReceived == [.selectSession(sessionId: "session-123", endpointId: nil)])
    #expect(otherReceived.isEmpty)
  }

  @Test func queuedCommandDispatchesWhenWindowBecomesFocused() {
    let center = AppExternalNavigationCenter()
    let windowID = UUID()
    var received: [AppExternalCommand] = []

    center.registerWindow(windowID) { command in
      received.append(command)
    }

    center.submitSessionSelection(sessionId: "session-123", endpointId: nil)
    #expect(received.isEmpty)

    center.updateFocusedWindow(windowID)

    #expect(received == [.selectSession(sessionId: "session-123", endpointId: nil)])
  }

  @Test func unregisteringFocusedWindowStopsDeliveryUntilAnotherWindowTakesFocus() {
    let center = AppExternalNavigationCenter()
    let firstWindowID = UUID()
    let secondWindowID = UUID()
    var firstReceived: [AppExternalCommand] = []
    var secondReceived: [AppExternalCommand] = []

    center.registerWindow(firstWindowID) { command in
      firstReceived.append(command)
    }
    center.registerWindow(secondWindowID) { command in
      secondReceived.append(command)
    }
    center.updateFocusedWindow(firstWindowID)
    center.unregisterWindow(firstWindowID)

    center.submitSessionSelection(sessionId: "session-456", endpointId: nil)
    #expect(firstReceived.isEmpty)
    #expect(secondReceived.isEmpty)

    center.updateFocusedWindow(secondWindowID)

    #expect(secondReceived == [.selectSession(sessionId: "session-456", endpointId: nil)])
  }
}
