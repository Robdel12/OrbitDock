import SwiftUI

@MainActor
@Observable
final class SettingsOpenAiNamingModel {
  var keyInput = ""
  var keySaved = false
  var status: SettingsOpenAiKeyStatus = .checking
  var isReplacingKey = false
  private var statusRequestId = UUID()

  func startReplacing() {
    isReplacingKey = true
    keySaved = false
  }

  func cancelReplacing() {
    isReplacingKey = false
    keyInput = ""
    keySaved = false
  }

  func save(
    using setKey: @escaping @Sendable (String) async throws -> Void,
    thenRefresh refresh: @escaping @Sendable () async -> Void
  ) {
    let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return }

    Task {
      try? await setKey(key)
      keySaved = true
      keyInput = ""
      isReplacingKey = false
      await refresh()
    }
  }

  func refresh(
    activeRuntimeId: UUID?,
    checkStatus: @escaping @Sendable () async throws -> Bool
  ) {
    guard activeRuntimeId != nil else {
      status = .notConfigured
      return
    }

    status = .checking
    let requestId = UUID()
    statusRequestId = requestId

    Task {
      do {
        let configured = try await checkStatus()
        guard shouldApply(requestId: requestId) else { return }
        status = configured ? .configured : .notConfigured
      } catch {
        guard shouldApply(requestId: requestId) else { return }
        status = .notConfigured
      }
    }
  }

  private func shouldApply(requestId: UUID) -> Bool {
    statusRequestId == requestId
  }
}
