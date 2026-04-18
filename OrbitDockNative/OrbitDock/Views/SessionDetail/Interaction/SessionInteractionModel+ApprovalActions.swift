import Foundation

extension SessionInteractionModel {
  func approveTool(
    decision: ApprovalsClient.ToolApprovalDecision,
    message: String? = nil,
    updatedInput: AnyCodable? = nil
  ) async {
    guard let session = currentSession,
          let requestId = pendingApproval?.requestId else { return }
    do {
      let response = try await session.api.approveTool(
        requestId: requestId,
        decision: decision,
        message: message,
        updatedInput: updatedInput
      )
      if let snapshot = response.sessionDetailSnapshot {
        acceptAuthoritativeDetailSnapshot(
          snapshot,
          source: "approval_response"
        )
      } else {
        clearPendingApprovalOptimistically()
        await refresh()
      }
    } catch {
      lastError = String(describing: error)
    }
  }

  func approveToolAlwaysAllowHost(_ host: String) async {
    let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedHost.isEmpty else {
      await approveTool(decision: .approvedAlways)
      return
    }

    let updatedInput = AnyCodable([
      "network_policy_amendment": [
        "host": normalizedHost,
        "action": "allow",
      ],
    ])
    await approveTool(decision: .approvedAlways, updatedInput: updatedInput)
  }

  func answerQuestion(answer: String, questionId: String? = nil) async {
    guard let session = currentSession,
          let requestId = pendingApproval?.requestId else { return }
    do {
      let response = try await session.api.answerQuestion(
        requestId: requestId,
        answer: answer,
        questionId: questionId
      )
      if let snapshot = response.sessionDetailSnapshot {
        acceptAuthoritativeDetailSnapshot(
          snapshot,
          source: "question_response"
        )
      } else {
        clearPendingApprovalOptimistically()
        await refresh()
      }
    } catch {
      lastError = String(describing: error)
    }
  }

  func answerQuestionBatch(answers: [String: [String]]) async {
    guard let session = currentSession,
          let requestId = pendingApproval?.requestId else { return }
    do {
      let response = try await session.api.answerQuestion(
        requestId: requestId,
        answer: "",
        questionId: nil,
        answers: answers
      )
      if let snapshot = response.sessionDetailSnapshot {
        acceptAuthoritativeDetailSnapshot(
          snapshot,
          source: "question_batch_response"
        )
      } else {
        clearPendingApprovalOptimistically()
        await refresh()
      }
    } catch {
      lastError = String(describing: error)
    }
  }

  func respondToPermission(grant: Bool, scope: ServerPermissionGrantScope = .turn) async {
    guard let session = currentSession,
          let requestId = pendingApproval?.requestId else { return }
    do {
      let response = try await session.api.respondToPermissionRequest(
        requestId: requestId,
        scope: scope,
        grantRequestedPermissions: grant
      )
      if let snapshot = response.sessionDetailSnapshot {
        acceptAuthoritativeDetailSnapshot(
          snapshot,
          source: "permission_response"
        )
      } else {
        clearPendingApprovalOptimistically()
        await refresh()
      }
    } catch {
      lastError = String(describing: error)
    }
  }
}
