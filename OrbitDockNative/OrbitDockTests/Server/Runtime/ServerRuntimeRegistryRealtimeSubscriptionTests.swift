import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ServerRuntimeRegistryRealtimeSubscriptionTests {
  // Dashboard subscription tests moved to DashboardViewModel-level testing.
  // The ServerConnection test helpers (seedDashboardSnapshotForTesting,
  // hasSubscribedDashboardStream) were removed with the surface-owned
  // architecture — each ViewModel now manages its own WS subscriptions.
}
