import Foundation

#if canImport(UIKit)
  import UIKit
#endif

struct AppLifecycleClient {
  let memoryWarnings: @MainActor () -> AsyncStream<Void>

  static func disabled() -> AppLifecycleClient {
    AppLifecycleClient(
      memoryWarnings: {
        AsyncStream { continuation in
          continuation.finish()
        }
      }
    )
  }

  #if canImport(UIKit)
    static func live() -> AppLifecycleClient {
      AppLifecycleClient(
        memoryWarnings: {
          AsyncStream { continuation in
            let observer = NotificationCenter.default.addObserver(
              forName: UIApplication.didReceiveMemoryWarningNotification,
              object: nil,
              queue: .main
            ) { _ in
              continuation.yield(())
            }

            continuation.onTermination = { _ in
              NotificationCenter.default.removeObserver(observer)
            }
          }
        }
      )
    }
  #else
    static func live() -> AppLifecycleClient {
      .disabled()
    }
  #endif
}
