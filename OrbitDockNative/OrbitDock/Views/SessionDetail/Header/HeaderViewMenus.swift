import SwiftUI

struct HeaderContinuationMenuSection: View {
  let continuation: SessionContinuation
  @Environment(AppRouter.self) private var router

  var body: some View {
    Section("Continue In New Session") {
      Button {
        router.openNewSession(provider: .claude, continuation: continuation)
      } label: {
        Label("Claude Session", systemImage: "sparkles")
      }

      Button {
        router.openNewSession(provider: .codex, continuation: continuation)
      } label: {
        Label("Codex Session", systemImage: "chevron.left.forwardslash.chevron.right")
      }
    }
  }
}

struct HeaderDebugContextMenu: View {
  let sessionId: String
  let threadId: String?
  let projectPath: String
  let provider: Provider
  let codexIntegrationMode: String?
  let claudeIntegrationMode: String?

  var body: some View {
    Button("Copy Session ID") {
      copyToClipboard(sessionId)
    }

    if let threadId {
      Button("Copy Thread ID") {
        copyToClipboard(threadId)
      }
    }

    Button("Copy Project Path") {
      copyToClipboard(projectPath)
    }

    Divider()

    if let codexIntegrationMode {
      Text("Integration: \(codexIntegrationMode)")
    }
    if let claudeIntegrationMode {
      Text("Integration: \(claudeIntegrationMode)")
    }
    Text("Provider: \(provider.rawValue)")

    Divider()
    Text("Server diagnostics are available through the server and CLI.")
  }

  private func copyToClipboard(_ text: String) {
    Platform.services.copyToClipboard(text)
  }
}
