import Foundation

extension SessionInteractionModel {
  func updateConfig(
    session: ServerSessionContext,
    configure: (inout SessionsClient.UpdateSessionConfigRequest) -> Void
  ) async throws {
    var request = SessionsClient.UpdateSessionConfigRequest()
    configure(&request)
    let requestData = configUpdateLogData(request: request)
    netLog(.info, cat: .store, "Session interaction config update requested", sid: session.sessionId, data: requestData)
    do {
      let updated = try await session.api.updateSessionConfig(
        approvalPolicy: request.approvalPolicy,
        approvalPolicyDetails: request.approvalPolicyDetails,
        sandboxMode: request.sandboxMode,
        approvalsReviewer: request.approvalsReviewer,
        permissionMode: request.permissionMode,
        collaborationMode: request.collaborationMode,
        multiAgent: request.multiAgent,
        personality: request.personality,
        serviceTier: request.serviceTier,
        developerInstructions: request.developerInstructions,
        model: request.model,
        effort: request.effort
      )
      netLog(
        .info,
        cat: .store,
        "Session interaction config update response received",
        sid: session.sessionId,
        data: snapshotLogData(snapshot: updated, source: "config_update_response")
      )
      acceptAuthoritativeDetailSnapshot(
        updated,
        source: "config_update"
      )
    } catch {
      var errorData = requestData
      errorData["error"] = String(describing: error)
      netLog(.error, cat: .store, "Session interaction config update failed", sid: session.sessionId, data: errorData)
      throw error
    }
  }

  func applyConfigUpdate(
    configure: (inout SessionsClient.UpdateSessionConfigRequest) -> Void
  ) async {
    guard let session = currentSession else { return }
    do {
      try await updateConfig(session: session, configure: configure)
    } catch {
      lastError = String(describing: error)
    }
  }

  func updateModel(_ model: String) async {
    await applyConfigUpdate { request in
      request.model = model
    }
  }

  func updateEffort(_ effort: String) async {
    await applyConfigUpdate { request in
      request.effort = effort
    }
  }

  func updatePermissionMode(_ mode: String) async {
    await applyConfigUpdate { request in
      request.permissionMode = mode
    }
  }

  func updateApprovalPolicy(_ policy: String) async {
    await applyConfigUpdate { request in
      request.approvalPolicy = policy
      request.approvalPolicyDetails = ServerCodexApprovalPolicy.fromLegacySummary(policy)
    }
  }

  func updateApprovalsReviewer(_ reviewer: ServerCodexApprovalsReviewer) async {
    await applyConfigUpdate { request in
      request.approvalsReviewer = reviewer
    }
  }

  func updateSandboxPolicy(_ policy: ServerCodexSandboxPolicy) async {
    await applyConfigUpdate { request in
      request.sandboxMode = policy.legacySummary
      request.sandboxPolicyDetails = policy
    }
  }

  func updateCollaborationMode(_ mode: String) async {
    await applyConfigUpdate { request in
      request.collaborationMode = mode
    }
  }

  func updateAutoReview(_ value: String) async {
    guard let option = snapshot?.capabilities.autoReviewOptions.first(where: { $0.value == value }) else {
      return
    }
    await applyConfigUpdate { request in
      request.approvalPolicy = option.approvalPolicy
      request.approvalPolicyDetails = option.approvalPolicyDetails
      request.sandboxMode = option.sandboxMode
      request.sandboxPolicyDetails = option.sandboxPolicyDetails
    }
  }
}
