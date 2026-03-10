import Testing
import UserNotifications
@testable import OrbitDock

#if os(macOS)
  import AppKit
#endif

@MainActor
struct NotificationManagerTests {
  @Test func configureAppSessionNotificationsOwnsDelegateAndCategoryRegistration() {
    var assignedDelegate: UNUserNotificationCenterDelegate?
    var registeredCategories: Set<UNNotificationCategory> = []

    let manager = NotificationManager(
      isAuthorized: false,
      requestsAuthorizationOnInit: false,
      notificationCenter: NotificationCenterClient(
        requestAuthorization: { _ in },
        setDelegate: { assignedDelegate = $0 },
        setNotificationCategories: { registeredCategories = $0 },
        addRequest: { _, _ in },
        removeDeliveredNotifications: { _ in }
      )
    )

    let delegate = TestNotificationDelegate()
    manager.configureAppSessionNotifications(delegate: delegate)

    #expect(assignedDelegate === delegate)
    #expect(registeredCategories.count == 1)
    let category = registeredCategories.first
    #expect(category?.identifier == "SESSION_ATTENTION")
    #expect(category?.actions.map(\.identifier) == ["VIEW_SESSION"])
  }
}

private final class TestNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {}
