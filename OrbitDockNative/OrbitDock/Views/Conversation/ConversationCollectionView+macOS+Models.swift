#if os(macOS)

  import Foundation

  extension ConversationCollectionViewController {
    func buildApprovalCardModel() -> ApprovalCardModel? {
      guard let sid = sessionId,
            let serverState,
            let session = serverState.sessions.first(where: { $0.id == sid })
      else { return nil }

      let pendingId = session.pendingApprovalId?.trimmingCharacters(in: .whitespacesAndNewlines)
      let pendingApproval: ServerApprovalRequest? = {
        guard let pendingId, !pendingId.isEmpty else { return nil }
        guard let candidate = serverState.session(sid).pendingApproval else { return nil }
        let candidateId = candidate.id.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidateId == pendingId ? candidate : nil
      }()

      return ApprovalCardModelBuilder.build(
        session: session,
        pendingApproval: pendingApproval,
        approvalHistory: serverState.session(sid).approvalHistory,
        transcriptMessages: serverState.conversation(sid).messages
      )
    }
  }

#endif
