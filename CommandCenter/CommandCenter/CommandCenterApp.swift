//
//  OrbitDockApp.swift
//  OrbitDock
//
//  Created by Robert DeLuca on 1/30/26.
//

import SwiftUI
import UserNotifications

@main
struct OrbitDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let database = DatabaseManager.shared

    var body: some Scene {
        // Main window
        WindowGroup {
            ContentView()
                .environment(database)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1000, height: 700)

        // Menu bar
        MenuBarExtra {
            MenuBarView()
                .environment(database)
        } label: {
            Image(systemName: "terminal.fill")
                .symbolRenderingMode(.monochrome)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up notification delegate
        UNUserNotificationCenter.current().delegate = self

        // Initialize notification manager (triggers authorization request)
        _ = NotificationManager.shared

        // Define notification actions
        let viewAction = UNNotificationAction(
            identifier: "VIEW_SESSION",
            title: "View Session",
            options: [.foreground]
        )

        let category = UNNotificationCategory(
            identifier: "SESSION_ATTENTION",
            actions: [viewAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // Handle notification when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound])
    }

    // Handle notification tap
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        if let sessionId = userInfo["sessionId"] as? String {
            // Post notification to select this session
            NotificationCenter.default.post(
                name: .selectSession,
                object: nil,
                userInfo: ["sessionId": sessionId]
            )
        }

        // Bring app to foreground
        NSApp.activate(ignoringOtherApps: true)

        completionHandler()
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let selectSession = Notification.Name("selectSession")
}
