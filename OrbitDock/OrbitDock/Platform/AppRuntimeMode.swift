import Foundation

enum AppRuntimeMode: String {
  case live
  case mock
  case remote

  enum Platform {
    case macOS
    case iOS
  }

  static let environmentKey = "ORBITDOCK_RUNTIME_MODE"

  static var current: AppRuntimeMode {
    let environment = ProcessInfo.processInfo.environment
    return resolved(
      environment: environment,
      hasRemoteEndpoint: isRunningTests(environment: environment) ? false : ServerEndpointSettings.hasRemoteEndpoint,
      isRunningTests: isRunningTests(environment: environment),
      platform: currentPlatform
    )
  }

  static var isRunningTestsProcess: Bool {
    isRunningTests(environment: ProcessInfo.processInfo.environment)
  }

  static func resolved(
    environment: [String: String],
    hasRemoteEndpoint: Bool,
    isRunningTests: Bool,
    platform: Platform
  ) -> AppRuntimeMode {
    if let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased(),
      let mode = AppRuntimeMode(rawValue: raw)
    {
      return mode
    }

    if isRunningTests {
      return .mock
    }

    switch platform {
      case .iOS:
        return hasRemoteEndpoint ? .remote : .mock
      case .macOS:
        return .live
    }
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

  private static func isRunningTests(environment: [String: String]) -> Bool {
    environment["XCTestConfigurationFilePath"] != nil
      || environment["XCTestBundlePath"] != nil
      || environment["XCTestSessionIdentifier"] != nil
  }

  private static var currentPlatform: Platform {
    #if os(iOS)
      .iOS
    #else
      .macOS
    #endif
  }
}
