import SwiftUI

enum SettingsEndpointHealthTone: Equatable, Sendable {
  case positive
  case mixed
  case warning
}

struct SettingsEndpointHealthSummary: Equatable, Sendable {
  let endpointCount: Int
  let enabledEndpointCount: Int
  let connectedEndpointCount: Int
  let tone: SettingsEndpointHealthTone
  let shortText: String
  let detailedText: String

  var color: Color {
    switch tone {
      case .positive:
        Color.feedbackPositive
      case .mixed:
        Color.statusQuestion
      case .warning:
        Color.statusPermission
    }
  }

  static func make(
    endpointCount: Int,
    enabledEndpointCount: Int,
    connectedEndpointCount: Int
  ) -> SettingsEndpointHealthSummary {
    if enabledEndpointCount == 0 {
      return SettingsEndpointHealthSummary(
        endpointCount: endpointCount,
        enabledEndpointCount: enabledEndpointCount,
        connectedEndpointCount: connectedEndpointCount,
        tone: .warning,
        shortText: "No enabled endpoints",
        detailedText: "No enabled endpoints"
      )
    }

    if connectedEndpointCount == enabledEndpointCount {
      let shortText = "\(connectedEndpointCount)/\(enabledEndpointCount) connected"
      return SettingsEndpointHealthSummary(
        endpointCount: endpointCount,
        enabledEndpointCount: enabledEndpointCount,
        connectedEndpointCount: connectedEndpointCount,
        tone: .positive,
        shortText: shortText,
        detailedText: "\(connectedEndpointCount) of \(enabledEndpointCount) enabled connected"
      )
    }

    if connectedEndpointCount > 0 {
      let shortText = "\(connectedEndpointCount)/\(enabledEndpointCount) connected"
      return SettingsEndpointHealthSummary(
        endpointCount: endpointCount,
        enabledEndpointCount: enabledEndpointCount,
        connectedEndpointCount: connectedEndpointCount,
        tone: .mixed,
        shortText: shortText,
        detailedText: "\(connectedEndpointCount) of \(enabledEndpointCount) enabled connected"
      )
    }

    let shortText = "0/\(enabledEndpointCount) connected"
    return SettingsEndpointHealthSummary(
      endpointCount: endpointCount,
      enabledEndpointCount: enabledEndpointCount,
      connectedEndpointCount: connectedEndpointCount,
      tone: .warning,
      shortText: shortText,
      detailedText: "0 of \(enabledEndpointCount) enabled connected"
    )
  }
}

extension SettingsEndpointHealthSummary {
  static func connectedEnabledEndpointCount(
    for runtimes: [ServerRuntime],
    statusForEndpointId: (UUID) -> ConnectionStatus
  ) -> Int {
    runtimes.filter { runtime in
      guard runtime.endpoint.isEnabled else { return false }
      if case .connected = statusForEndpointId(runtime.id) {
        return true
      }
      return false
    }.count
  }

  static func current(for runtimeRegistry: ServerRuntimeRegistry) -> SettingsEndpointHealthSummary {
    let endpointCount = runtimeRegistry.runtimes.count
    let enabledEndpointCount = runtimeRegistry.runtimes.filter(\.endpoint.isEnabled).count
    let connectedEndpointCount = connectedEnabledEndpointCount(for: runtimeRegistry.runtimes) {
      runtimeRegistry.displayConnectionStatus(for: $0)
    }

    return make(
      endpointCount: endpointCount,
      enabledEndpointCount: enabledEndpointCount,
      connectedEndpointCount: connectedEndpointCount
    )
  }
}
