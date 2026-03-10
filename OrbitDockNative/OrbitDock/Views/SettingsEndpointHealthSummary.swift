import Foundation

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
