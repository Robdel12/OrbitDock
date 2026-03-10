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
      shouldRequestAuthorizationOnStart: false,
      notificationCenter: NotificationCenterClient(
        requestAuthorization: { _ in },
        setDelegate: { assignedDelegate = $0 },
        setNotificationCategories: { registeredCategories = $0 },
        addRequest: { _, _ in },
        removeDeliveredNotifications: { _ in }
      ),
      preferences: NotificationPreferences(
        stringForKey: { _ in nil },
        objectForKey: { _ in nil },
        boolForKey: { _ in false }
      ),
      isRunningTestsProcess: false
    )

    let delegate = TestNotificationDelegate()
    manager.configureAppSessionNotifications(delegate: delegate)

    #expect(assignedDelegate === delegate)
    #expect(registeredCategories.count == 1)
    let category = registeredCategories.first
    #expect(category?.identifier == "SESSION_ATTENTION")
    #expect(category?.actions.map(\.identifier) == ["VIEW_SESSION"])
  }

  @Test func sendTestNotificationUsesInjectedNotificationCenter() {
    var addedRequest: UNNotificationRequest?

    let manager = NotificationManager(
      isAuthorized: true,
      shouldRequestAuthorizationOnStart: false,
      notificationCenter: NotificationCenterClient(
        requestAuthorization: { _ in },
        setDelegate: { _ in },
        setNotificationCategories: { _ in },
        addRequest: { request, _ in addedRequest = request },
        removeDeliveredNotifications: { _ in }
      ),
      preferences: NotificationPreferences(
        stringForKey: { _ in nil },
        objectForKey: { _ in nil },
        boolForKey: { _ in false }
      ),
      isRunningTestsProcess: false
    )

    manager.sendTestNotification(soundID: "default")

    #expect(addedRequest?.content.title == "Test Notification")
    #expect(addedRequest?.content.subtitle == "OrbitDock")
    #expect(addedRequest?.content.categoryIdentifier == "SESSION_ATTENTION")
  }

  @Test func startIfNeededRequestsAuthorizationAtTheBoundary() {
    var requestCount = 0

    let manager = NotificationManager(
      isAuthorized: false,
      shouldRequestAuthorizationOnStart: true,
      notificationCenter: NotificationCenterClient(
        requestAuthorization: { completion in
          requestCount += 1
          completion(false, nil)
        },
        setDelegate: { _ in },
        setNotificationCategories: { _ in },
        addRequest: { _, _ in },
        removeDeliveredNotifications: { _ in }
      ),
      preferences: NotificationPreferences(
        stringForKey: { _ in nil },
        objectForKey: { _ in nil },
        boolForKey: { _ in false }
      ),
      isRunningTestsProcess: false
    )

    manager.startIfNeeded()
    manager.startIfNeeded()

    #expect(requestCount == 1)
  }
}

private final class TestNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {}
