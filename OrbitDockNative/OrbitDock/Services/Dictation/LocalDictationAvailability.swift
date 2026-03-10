//
//  LocalDictationAvailability.swift
//  OrbitDock
//

import Foundation

nonisolated enum LocalDictationAvailability: Equatable, Sendable {
  case available
  case unavailable
}

nonisolated enum LocalDictationAvailabilityResolver {
  static func resolve(appleSpeechSupported: Bool) -> LocalDictationAvailability {
    appleSpeechSupported ? .available : .unavailable
  }

  static var current: LocalDictationAvailability {
    resolve(appleSpeechSupported: appleSpeechSupportedOnCurrentOS)
  }

  static var appleSpeechSupportedOnCurrentOS: Bool {
    #if canImport(Speech)
      if #available(macOS 26.0, iOS 26.0, *) {
        return true
      }
    #endif

    return false
  }
}
