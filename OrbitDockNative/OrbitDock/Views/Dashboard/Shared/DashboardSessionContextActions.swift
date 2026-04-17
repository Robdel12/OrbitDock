import SwiftUI

enum DashboardSessionContextActions {
  @ViewBuilder
  static func rootSessionBaseActions(for session: RootSessionNode) -> some View {
    baseActions(
      projectPath: session.projectPath,
      resumeCommand: "claude --resume \(session.id)"
    )
  }

  @ViewBuilder
  static func conversationBaseActions(for session: DashboardConversationRecord) -> some View {
    baseActions(
      projectPath: session.projectPath,
      resumeCommand: "claude --resume \(session.sessionId)"
    )
  }

  @ViewBuilder
  private static func baseActions(projectPath: String, resumeCommand: String) -> some View {
    Button {
      _ = Platform.services.revealInFileBrowser(projectPath)
    } label: {
      Label("Reveal in Finder", systemImage: "folder")
    }

    Button {
      Platform.services.copyToClipboard(resumeCommand)
    } label: {
      Label("Copy Resume Command", systemImage: "doc.on.doc")
    }
  }
}
