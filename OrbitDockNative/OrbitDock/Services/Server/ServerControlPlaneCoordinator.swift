import Foundation

struct ServerPrimaryClaimUpdate: Sendable {
  let endpointId: UUID
  let isPrimary: Bool

  nonisolated static func == (lhs: ServerPrimaryClaimUpdate, rhs: ServerPrimaryClaimUpdate) -> Bool {
    lhs.endpointId == rhs.endpointId && lhs.isPrimary == rhs.isPrimary
  }
}

extension ServerPrimaryClaimUpdate: Equatable {}

struct ServerControlPlanePlan: Sendable {
  let enabledEndpointIds: [UUID]
  let primaryEndpointId: UUID?

  nonisolated static func == (lhs: ServerControlPlanePlan, rhs: ServerControlPlanePlan) -> Bool {
    lhs.enabledEndpointIds == rhs.enabledEndpointIds && lhs.primaryEndpointId == rhs.primaryEndpointId
  }
}

extension ServerControlPlanePlan: Equatable {}

enum ServerPrimaryClaimPlanner {
  nonisolated static func desiredAssignments(
    enabledEndpointIds: [UUID],
    primaryEndpointId: UUID?
  ) -> [UUID: Bool] {
    Dictionary(uniqueKeysWithValues: enabledEndpointIds.map { endpointId in
      (endpointId, endpointId == primaryEndpointId)
    })
  }

  nonisolated static func updates(
    enabledEndpointIds: [UUID],
    primaryEndpointId: UUID?,
    previousAssignments: [UUID: Bool]
  ) -> [ServerPrimaryClaimUpdate] {
    enabledEndpointIds.compactMap { endpointId in
      let desired = primaryEndpointId == endpointId
      guard previousAssignments[endpointId] != desired else { return nil }
      return ServerPrimaryClaimUpdate(endpointId: endpointId, isPrimary: desired)
    }
  }
}

struct ServerControlPlanePort: Sendable {
  let endpointId: UUID
  let client: ControlPlaneClient
}

actor ServerControlPlaneCoordinator {
  private var appliedPrimaryClaimAssignments: [UUID: Bool] = [:]
  private var pendingPrimaryClaimPlan: ServerControlPlanePlan?
  private var pendingPrimaryClaimPorts: [UUID: ServerControlPlanePort] = [:]
  private var pendingClientIdentity: ServerClientIdentity?
  private var isProcessingPrimaryClaims = false
  private var processingTask: Task<Void, Never>?

  func submitPrimaryClaimPlan(
    _ plan: ServerControlPlanePlan,
    ports: [ServerControlPlanePort],
    clientIdentity: ServerClientIdentity
  ) {
    pendingPrimaryClaimPlan = plan
    pendingPrimaryClaimPorts = Dictionary(uniqueKeysWithValues: ports.map { ($0.endpointId, $0) })
    pendingClientIdentity = clientIdentity

    guard !isProcessingPrimaryClaims else { return }
    isProcessingPrimaryClaims = true

    let task = Task {
      await processPrimaryClaimPlans()
    }
    processingTask = task
  }

  func applyServerRoleChange(
    endpointId: UUID,
    isPrimary: Bool,
    ports: [ServerControlPlanePort]
  ) async {
    let sortedPorts = ports.sorted { $0.endpointId.uuidString < $1.endpointId.uuidString }

    if isPrimary {
      for port in sortedPorts where port.endpointId != endpointId {
        do {
          _ = try await port.client.setServerRole(false)
        } catch {
          // Log failure silently
        }
      }
    }

    guard let targetPort = sortedPorts.first(where: { $0.endpointId == endpointId }) else {
      return
    }

    do {
      _ = try await targetPort.client.setServerRole(isPrimary)
    } catch {
      // Log failure silently
    }
  }

  private func processPrimaryClaimPlans() async {
    while true {
      guard let plan = pendingPrimaryClaimPlan, let clientIdentity = pendingClientIdentity else {
        isProcessingPrimaryClaims = false
        processingTask = nil
        return
      }

      let portsByEndpointId = pendingPrimaryClaimPorts
      pendingPrimaryClaimPlan = nil
      pendingClientIdentity = nil
      pendingPrimaryClaimPorts = [:]

      let enabledEndpointIds = Set(plan.enabledEndpointIds)
      appliedPrimaryClaimAssignments = appliedPrimaryClaimAssignments.filter { enabledEndpointIds.contains($0.key) }

      let updates = ServerPrimaryClaimPlanner.updates(
        enabledEndpointIds: plan.enabledEndpointIds,
        primaryEndpointId: plan.primaryEndpointId,
        previousAssignments: appliedPrimaryClaimAssignments
      )

      for update in updates {
        guard let port = portsByEndpointId[update.endpointId] else { continue }

        do {
          try await port.client.setClientPrimaryClaim(clientIdentity, update.isPrimary)
          appliedPrimaryClaimAssignments[update.endpointId] = update.isPrimary
        } catch {
          // Log failure silently
        }
      }
    }
  }

  func waitUntilIdleForTests() async {
    let task = processingTask
    await task?.value
  }
}
