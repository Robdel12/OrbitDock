//
//  AppleScriptService.swift
//  OrbitDock
//
//  Generic AppleScript execution service using in-process NSAppleScript
//  for proper TCC permission dialog presentation.
//

import Cocoa
import Foundation

final class AppleScriptService {
  static let shared = AppleScriptService()

  private init() {}

  /// Execute an AppleScript in-process and return the result.
  /// Runs on the main thread so macOS can present the TCC automation consent dialog.
  func execute(_ script: String) async throws -> String? {
    try await MainActor.run {
      var errorInfo: NSDictionary?
      let appleScript = NSAppleScript(source: script)
      let result = appleScript?.executeAndReturnError(&errorInfo)

      if let errorInfo {
        let message = errorInfo[NSAppleScript.errorMessage] as? String
          ?? "Unknown AppleScript error"
        throw AppleScriptError.executionFailed(message)
      }

      return result?.stringValue
    }
  }

  /// Callback-based variant for code paths that need it (e.g. sendInput).
  func execute(_ script: String, completion: @escaping (Result<String?, Error>) -> Void) {
    Task {
      do {
        let result = try await execute(script)
        await MainActor.run { completion(.success(result)) }
      } catch {
        await MainActor.run { completion(.failure(error)) }
      }
    }
  }
}

enum AppleScriptError: Error, LocalizedError {
  case executionFailed(String)

  var errorDescription: String? {
    switch self {
      case let .executionFailed(message):
        "AppleScript execution failed: \(message)"
    }
  }
}
