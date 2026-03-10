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

    Button("Open Server Log") {
      _ = Platform.services.openURL(URL(fileURLWithPath: NSString("~/.orbitdock/logs/server.log").expandingTildeInPath))
    }

    if provider == .codex {
      Button("Open Codex Log") {
        _ = Platform.services
          .openURL(URL(fileURLWithPath: NSString("~/.orbitdock/logs/codex.log").expandingTildeInPath))
      }
    }

    Button("Open Database") {
      _ = Platform.services.openURL(URL(fileURLWithPath: NSString("~/.orbitdock/orbitdock.db").expandingTildeInPath))
    }
  }

  private func copyToClipboard(_ text: String) {
    Platform.services.copyToClipboard(text)
  }
}
