import SwiftUI
#if os(macOS)
  import AppKit
#endif

@main
struct OrbitDockApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  #endif

  private let connection: ServerConnection

  init() {
    let endpoint = ServerEndpointSettings.loadEndpoints().first(where: \.isEnabled)
      ?? ServerEndpoint.localDefault()
    self.connection = ServerConnection(endpoint: endpoint)
  }

  var body: some Scene {
    #if os(macOS)
      WindowGroup {
        OrbitDockWindowRoot(connection: connection)
          .frame(minWidth: 1_000, maxWidth: .infinity, minHeight: 700, maxHeight: .infinity)
      }
      .windowStyle(.hiddenTitleBar)
      .defaultSize(width: 1_000, height: 700)
    #else
      WindowGroup {
        OrbitDockWindowRoot(connection: connection)
      }
    #endif
  }
}

// MARK: - App Delegate

#if os(macOS)
  class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
      UserDefaults.standard.set(false, forKey: "NSTableViewCanEstimateRowHeights")
      NSApp.appearance = NSAppearance(named: .darkAqua)
    }
  }
#endif
