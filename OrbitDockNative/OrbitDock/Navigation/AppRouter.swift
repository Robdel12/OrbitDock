import SwiftUI

enum AppRoute: Equatable {
  case dashboard
  case session(SessionRef)
}

@Observable
@MainActor
final class AppRouter {
  var route: AppRoute = .dashboard

  func selectSession(_ ref: SessionRef) {
    print("[OrbitDock][Router] selectSession scopedID=\(ref.scopedID)")
    route = .session(ref)
  }

  func goToDashboard() {
    print("[OrbitDock][Router] goToDashboard")
    route = .dashboard
  }

  var selectedSessionRef: SessionRef? {
    guard case let .session(ref) = route else { return nil }
    return ref
  }
}
