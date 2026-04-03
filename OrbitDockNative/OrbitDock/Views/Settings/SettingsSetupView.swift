import SwiftUI

struct SetupSettingsView: View {
  let serverState: SessionStore
  @State private var viewModel: CodexAccountSetupViewModel
  private var bindingIdentity: String {
    "\(serverState.endpointId.uuidString):\(ObjectIdentifier(serverState))"
  }

  init(serverState: SessionStore) {
    self.serverState = serverState
    _viewModel = State(initialValue: CodexAccountSetupViewModel(serverState: serverState))
  }

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        CodexAccountSetupPane(viewModel: viewModel)
      }
      .padding(.horizontal, Spacing.section)
      .padding(.vertical, Spacing.section)
      .frame(maxWidth: 980, alignment: .leading)
    }
    .task(id: bindingIdentity) {
      viewModel.update(serverState: serverState)
      viewModel.refresh()
    }
  }
}
