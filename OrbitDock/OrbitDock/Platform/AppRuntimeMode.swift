import Foundation

enum AppRuntimeMode: String {
  case live
  case mock
  case remote

  static let environmentKey = "ORBITDOCK_RUNTIME_MODE"

  static var current: AppRuntimeMode {
    if let raw = ProcessInfo.processInfo.environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased(),
      let mode = AppRuntimeMode(rawValue: raw)
    {
      return mode
    }

    #if os(iOS)
      // iOS checks for a saved remote host — if one exists, use remote mode
      if ServerEndpointSettings.remoteHost != nil {
        return .remote
      }
      return .mock
    #else
      return .live
    #endif
  }

  var shouldConnectServer: Bool {
    self == .live || self == .remote
  }

  var shouldStartMcpBridge: Bool {
    #if os(macOS)
      self == .live || self == .remote
    #else
      false
    #endif
  }
}
