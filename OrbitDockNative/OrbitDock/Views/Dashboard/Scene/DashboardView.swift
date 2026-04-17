import SwiftUI

struct DashboardView: View {
  @Environment(AppRouter.self) private var router
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(LibraryDataService.self) private var libraryDataService
  let viewModel: DashboardViewModel

  var body: some View {
    GeometryReader { proxy in
      let containerWidth = proxy.size.width

      VStack(spacing: 0) {
        switch router.dashboardTab {
          case .missionControl:
            OverviewPanel(viewModel: viewModel)
          case .missions:
            missionsTab
          case .library:
            LibraryView(
              sessions: libraryDataService.sessions,
              hasMoreSessions: libraryDataService.hasMoreSessions,
              onLoadMoreSessions: {
                await libraryDataService.loadMore(runtimeRegistry: runtimeRegistry)
              },
              containerWidth: containerWidth
            )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.backgroundPrimary)
      .task(id: router.dashboardTab) {
        guard router.dashboardTab == .library else {
          libraryDataService.stopLiveUpdates()
          return
        }
        libraryDataService.startLiveUpdates(runtimeRegistry: runtimeRegistry)
        await libraryDataService.refreshNow(runtimeRegistry: runtimeRegistry)
      }
    }
    .onDisappear {
      libraryDataService.stopLiveUpdates()
    }
    .navigationTitle(router.dashboardTab.navigationTitle)
    .toolbarTitleDisplayMode(.inline)
    .refreshable {
      switch router.dashboardTab {
        case .missionControl:
          await viewModel.refreshNow()
        case .missions:
          break
        case .library:
          await libraryDataService.refreshNow(runtimeRegistry: runtimeRegistry)
      }
    }
  }

  // MARK: - Missions Tab

  @ViewBuilder
  private var missionsTab: some View {
    if runtimeRegistry.hasConfiguredEndpoints {
      MissionListView()
    } else {
      ContentUnavailableView(
        "No Server Connected",
        systemImage: "server.rack",
        description: Text("Connect to a server to view missions")
      )
    }
  }
}

#Preview {
  let runtimeRegistry = ServerRuntimeRegistry(
    endpointsProvider: { [] },
    runtimeFactory: { ServerRuntime(endpoint: $0) },
    shouldBootstrapFromSettings: false
  )
  let router = AppRouter()
  let dataService = DashboardDataService()
  let libraryDataService = LibraryDataService()
  DashboardView(viewModel: DashboardViewModel(dataService: dataService))
    .frame(width: 900, height: 500)
    .environment(runtimeRegistry)
    .environment(router)
    .environment(libraryDataService)
}
