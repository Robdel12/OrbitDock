import SwiftUI

enum DashboardSessionContextActions {
  @ViewBuilder
  static func rootSessionBaseActions(for session: RootSessionNode) -> some View {
    baseActions(
      projectPath: session.projectPath,
      resumeCommand: session.provider.resumeCommand(sessionId: session.sessionId)
    )
  }

  @ViewBuilder
  static func conversationBaseActions(for session: DashboardConversationRecord) -> some View {
    baseActions(
      projectPath: session.projectPath,
      resumeCommand: session.provider.resumeCommand(sessionId: session.sessionId)
    )
  }

  @ViewBuilder
  static func pinActions(
    for session: DashboardConversationRecord,
    pinnedService: PinnedSessionsService
  ) -> some View {
    let isPinned = pinnedService.isPinned(session.sessionRef)

    Button {
      pinnedService.toggle(session.sessionRef)
    } label: {
      Label(
        isPinned ? "Unpin" : "Pin",
        systemImage: isPinned ? "pin.slash" : "pin"
      )
    }
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
