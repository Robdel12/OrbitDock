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

  @MainActor
  static var current: AppRuntimeMode {
    current(
      environment: ProcessInfo.processInfo.environment,
      endpointSettings: .live(),
      isRunningTests: isRunningTests(environment: ProcessInfo.processInfo.environment),
      platform: currentPlatform
    )
  }

  @MainActor
  static func current(
    environment: [String: String],
    endpointSettings: ServerEndpointSettingsClient,
    isRunningTests: Bool,
    platform: Platform
  ) -> AppRuntimeMode {
    return resolved(
      environment: environment,
      hasRemoteEndpoint: isRunningTests ? false : endpointSettings.hasRemoteEndpoint(),
      isRunningTests: isRunningTests,
      platform: platform
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
