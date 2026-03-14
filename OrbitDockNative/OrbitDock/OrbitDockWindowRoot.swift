import SwiftUI

struct OrbitDockWindowRoot: View {
  @State private var appStore: AppStore
  @State private var router = AppRouter()

  init(connection: ServerConnection) {
    _appStore = State(initialValue: AppStore(connection: connection))
  }

  var body: some View {
    Group {
      switch router.route {
      case .dashboard:
        DashboardView()
          .onAppear {
            print("[OrbitDock][WindowRoot] showing dashboard")
          }
      case let .session(ref):
        SessionDetailView(
          sessionId: ref.sessionId,
          endpointId: ref.endpointId
        )
        .id(ref.scopedID)
        .onAppear {
          print("[OrbitDock][WindowRoot] showing session \(ref.scopedID)")
        }
      }
    }
    .environment(appStore)
    .environment(router)
    .environment(appStore.connection)
    .preferredColorScheme(.dark)
    .background(Color.backgroundPrimary)
    .task {
      appStore.start()
    }
    .onChange(of: router.route) { _, newRoute in
      print("[OrbitDock][WindowRoot] route changed to \(newRoute)")
    }
  }
}
