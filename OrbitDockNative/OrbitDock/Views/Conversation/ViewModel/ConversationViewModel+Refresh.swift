import SwiftUI

extension ConversationViewModel {
  /// Conversation owns its initial HTTP bootstrap.
  /// We still consume WS row deltas and explicit resync requests afterward,
  /// but first load should not depend on some other scene-side race.
  func refresh(forceHTTPResync: Bool = false) async {
    guard currentSessionId?.isEmpty == false else { return }
    requestRefresh(forceHTTPResync: forceHTTPResync)
    await refreshRunner.waitForCurrentRefresh()
  }

  func handleConversationRowDelta(_ delta: ServerSessionTransport.ConversationRowDelta) {
    applyDelta(delta)
  }

  func requestForcedResync(revision: UInt64?) {
    guard canStartForcedResync(for: revision) else { return }
    if let revision {
      pendingForcedResyncRevision = max(pendingForcedResyncRevision ?? revision, revision)
    }
    requestRefresh(forceHTTPResync: true)
  }

  func loadOlderMessages() {
    guard let currentSessionId, hasMoreBefore, !isLoadingOlder else { return }
    guard let oldestSequence = rowEntries.first?.sequence else { return }
    isLoadingOlder = true
    let session = currentSession

    Task {
      defer { isLoadingOlder = false }
      do {
        let page = try await session.api.fetchConversationHistory(
          beforeSequence: oldestSequence,
          limit: pageSize
        )
        guard self.currentSessionId == currentSessionId, self.currentSession === session else { return }
        let mergedPage = ConversationHistoryPaging.mergeOlderPage(
          existingRows: rowEntries,
          page: page
        )
        hasMoreBefore = mergedPage.hasMoreBefore
        totalRowCount = mergedPage.totalRowCount
        rowEntries = mergedPage.rows
        structureRevision += 1
        contentRevision += 1
        rebuildPresentation(
          changedEntries: page.rows,
          appendedEntryCount: 0,
          visibilityEventRowID: nil
        )
      } catch {
        netLog(.error, cat: .store, "Load older messages failed", sid: currentSessionId, data: [
          "error": String(describing: error),
        ])
      }
    }
  }

  func requestRefresh(forceHTTPResync: Bool = false) {
    if forceHTTPResync {
      pendingForceHTTPResync = true
    }
    refreshRunner.schedule { [weak self] in
      await self?.performRefreshCycle()
    }
  }

  func performRefreshCycle() async {
    guard let sessionId = currentSessionId, !sessionId.isEmpty else { return }
    let requestedForcedResyncRevision = pendingForcedResyncRevision
    let isUnversionedForcedResync = pendingForceHTTPResync && requestedForcedResyncRevision == nil
    let shouldForceHTTPResync = shouldRunForcedResync(
      requested: pendingForceHTTPResync,
      revision: requestedForcedResyncRevision
    )
    pendingForceHTTPResync = false
    pendingForcedResyncRevision = nil

    let session = currentSession
    let needsInitialBootstrap = !conversationLoaded && rowEntries.isEmpty
    if needsInitialBootstrap || shouldForceHTTPResync {
      isRefreshInFlight = true
      defer {
        isRefreshInFlight = false
      }
      do {
        let bootstrap = try await session.api.fetchConversationBootstrap(
          limit: pageSize,
          source: needsInitialBootstrap ? "conversation-initial" : "conversation-resync"
        )
        guard currentSessionId == sessionId, currentSession === session else { return }
        session.transport.recordRevision(bootstrap.replayCursor)
        applyBootstrap(bootstrap, session: session)
        if shouldForceHTTPResync {
          markForcedResyncCompleted(
            revision: max(requestedForcedResyncRevision ?? 0, bootstrap.replayCursor)
          )
          markUnversionedForcedResyncCompletedIfNeeded(isUnversionedForcedResync)
        }
      } catch {
        netLog(
          .error,
          cat: .conv,
          "Conversation bootstrap fetch failed during refresh",
          sid: sessionId,
          data: [
            "initialBootstrap": needsInitialBootstrap ? "true" : "false",
            "currentSessionId": currentSessionId ?? "nil",
            "error": error.localizedDescription,
          ]
        )
        if let requestError = error as? ServerRequestError,
           requestError.isIncompatibleClientUpgradeRequired,
           case let .httpStatus(_, _, message) = requestError,
           let message,
           !message.isEmpty
        {
          session.endpointRuntime.connection.failConnection(message: message)
        }

        if needsInitialBootstrap {
          guard currentSessionId == sessionId else { return }
          if rowEntries.isEmpty {
            conversationLoaded = true
            rebuildPresentation(changedEntries: [])
          }
        } else {
          netLog(
            .error,
            cat: .conv,
            "Conversation bootstrap fetch failed",
            sid: sessionId,
            data: ["error": error.localizedDescription]
          )
        }
      }
    }
  }

  func shouldRunForcedResync(
    requested: Bool,
    revision: UInt64?
  ) -> Bool {
    guard requested else { return false }
    guard let revision else {
      if let lastCompletedForcedResyncRevision,
         lastCompletedUnversionedForcedResyncCursor == lastCompletedForcedResyncRevision
      {
        return false
      }
      return true
    }
    if let lastCompletedForcedResyncRevision, revision <= lastCompletedForcedResyncRevision {
      return false
    }
    return true
  }

  func canStartForcedResync(for revision: UInt64?) -> Bool {
    if let revision,
       let lastCompletedForcedResyncRevision,
       revision <= lastCompletedForcedResyncRevision
    {
      return false
    }
    return true
  }

  func markForcedResyncCompleted(revision: UInt64?) {
    guard let revision else { return }
    lastCompletedForcedResyncRevision = max(lastCompletedForcedResyncRevision ?? revision, revision)
  }

  func markUnversionedForcedResyncCompletedIfNeeded(_ isUnversionedForcedResync: Bool) {
    guard isUnversionedForcedResync else { return }
    lastCompletedUnversionedForcedResyncCursor = lastCompletedForcedResyncRevision
  }
}
