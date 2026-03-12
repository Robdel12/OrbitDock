#if os(macOS)

  import Foundation

  extension ConversationCollectionViewController {
    func refreshRowContextCaches() {
      rowContextSubagentsByID = Dictionary(
        uniqueKeysWithValues: serverState?.session(sessionId ?? "").subagents.map { ($0.id, $0) } ?? []
      )
      rowContextApprovalCardModel = buildApprovalCardModel()
      rowContextCompactToolModelsByMessageID = messagesByID.compactMapValues { message in
        guard message.isTool || message.isShell else { return nil }
        return SharedModelBuilders.compactToolModel(
          from: message,
          supportsRichToolingCards: sourceState.metadata.supportsRichToolingCards,
          subagentsByID: rowContextSubagentsByID,
          selectedWorkerID: selectedWorkerID
        )
      }
      rowContextWorkerEventModelsByMessageID = messagesByID.compactMapValues { message in
        SharedModelBuilders.workerEventModel(
          from: message,
          subagentsByID: rowContextSubagentsByID,
          selectedWorkerID: selectedWorkerID
        )
      }
    }

    func buildApprovalCardModel() -> ApprovalCardModel? {
      guard let sid = sessionId,
            let serverState
      else { return nil }
      let observable = serverState.session(sid)
      let pendingId = observable.pendingApprovalId?.trimmingCharacters(in: .whitespacesAndNewlines)
      let pendingApproval: ServerApprovalRequest? = {
        guard let pendingId, !pendingId.isEmpty else { return nil }
        guard let candidate = observable.pendingApproval else { return nil }
        let candidateId = candidate.id.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidateId == pendingId ? candidate : nil
      }()

      return ApprovalCardModelBuilder.build(
        session: observable.approvalCardContext,
        pendingApproval: pendingApproval,
        approvalHistory: observable.approvalHistory,
        transcriptMessages: serverState.conversation(sid).messages
      )
    }
  }

#endif
