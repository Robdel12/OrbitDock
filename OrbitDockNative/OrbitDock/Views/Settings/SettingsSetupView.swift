import SwiftUI

struct SetupSettingsView: View {
  let serverState: SessionStore

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        CodexAccountSetupPane(serverState: serverState)
      }
      .padding(Spacing.xl)
    }
    .task(id: serverState.endpointId) {
      serverState.refreshCodexAccount()
    }
  }
}
