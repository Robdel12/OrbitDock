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
      // iOS uses remote mode when a remote endpoint is configured.
      if ServerEndpointSettings.hasRemoteEndpoint {
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
      #if DEBUG
        let enabledForDebug = ProcessInfo.processInfo.environment["ORBITDOCK_ENABLE_MCP_BRIDGE"] == "1"
        return enabledForDebug && (self == .live || self == .remote)
      #else
        false
      #endif
    #else
      false
    #endif
  }
}
