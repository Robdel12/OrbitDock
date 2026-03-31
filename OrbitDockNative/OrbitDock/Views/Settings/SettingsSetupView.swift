import SwiftUI

struct SetupSettingsView: View {
  let serverState: SessionStore

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        CodexAccountSetupPane(serverState: serverState)
      }
      .padding(.horizontal, Spacing.section)
      .padding(.vertical, Spacing.section)
      .frame(maxWidth: 980, alignment: .leading)
    }
    .task(id: serverState.endpointId) {
      serverState.refreshCodexAccount()
    }
  }
}
