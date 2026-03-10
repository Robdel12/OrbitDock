import SwiftUI

struct SetupSettingsView: View {
  @Environment(SessionStore.self) private var serverState
  @State private var model = SetupSettingsModel()

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        ClaudeHooksSetupPane(model: model)
        CodexAccountSetupPane()
      }
      .padding(Spacing.xl)
    }
    .task {
      model.refreshHooksConfiguration()
      serverState.refreshCodexAccount()
    }
  }
}
