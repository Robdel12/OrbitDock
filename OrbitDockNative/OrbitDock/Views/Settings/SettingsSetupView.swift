import SwiftUI

struct SetupSettingsView: View {
  let endpointStore: ServerEndpointRuntime
  @State private var viewModel: CodexAccountSetupViewModel
  private var bindingIdentity: String {
    "\(endpointStore.endpointId.uuidString):\(ObjectIdentifier(endpointStore))"
  }

  init(endpointStore: ServerEndpointRuntime) {
    self.endpointStore = endpointStore
    _viewModel = State(initialValue: CodexAccountSetupViewModel(endpointStore: endpointStore))
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
      viewModel.update(endpointStore: endpointStore)
      viewModel.refresh()
    }
  }
}
