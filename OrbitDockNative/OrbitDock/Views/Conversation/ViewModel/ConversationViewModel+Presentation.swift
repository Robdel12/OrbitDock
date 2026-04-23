import SwiftUI

extension ConversationViewModel {
  func applyBootstrap(_ bootstrap: ServerConversationBootstrap, session: ServerSessionContext) {
    lastCompletedForcedResyncRevision = max(
      lastCompletedForcedResyncRevision ?? bootstrap.replayCursor,
      bootstrap.replayCursor
    )
    let mergedBootstrap = ConversationHistoryPaging.mergeBootstrap(
      existingRows: rowEntries,
      existingHasMoreBefore: hasMoreBefore,
      existingTotalRowCount: totalRowCount,
      bootstrapRows: bootstrap.rows,
      bootstrapHasMoreBefore: bootstrap.hasMoreBefore,
      bootstrapTotalRowCount: bootstrap.totalRowCount
    )
    rowEntries = mergedBootstrap.rows
    hasMoreBefore = mergedBootstrap.hasMoreBefore
    totalRowCount = mergedBootstrap.totalRowCount
    conversationLoaded = true
    structureRevision += 1
    contentRevision += 1
    rebuildPresentation(
      changedEntries: bootstrap.rows,
      appendedEntryCount: 0,
      visibilityEventRowID: nil
    )

    if let sourceId = bootstrap.forkedFromSessionId {
      forkOrigin = ConversationForkOriginPresentation(
        sourceSessionId: sourceId,
        sourceEndpointId: session.endpointId,
        sourceName: nil
      )
    } else {
      forkOrigin = nil
    }
  }

  func applyAgentThreadPage(_ page: ServerAgentThreadConversationPage) {
    let mergedPage = ConversationHistoryPaging.mergeBootstrap(
      existingRows: rowEntries,
      existingHasMoreBefore: hasMoreBefore,
      existingTotalRowCount: totalRowCount,
      bootstrapRows: page.rows,
      bootstrapHasMoreBefore: page.hasMoreBefore,
      bootstrapTotalRowCount: page.totalRowCount
    )
    rowEntries = mergedPage.rows
    hasMoreBefore = mergedPage.hasMoreBefore
    totalRowCount = mergedPage.totalRowCount
    conversationLoaded = true
    forkOrigin = nil
    structureRevision += 1
    contentRevision += 1
    rebuildPresentation(
      changedEntries: page.rows,
      appendedEntryCount: 0,
      visibilityEventRowID: nil
    )
  }

  func applyDelta(_ delta: ServerSessionTransport.ConversationRowDelta) {
    conversationLoaded = true

    var changed: [ServerConversationRowEntry] = []
    var structureChanged = false

    if !delta.removedIds.isEmpty {
      let removedSet = Set(delta.removedIds)
      rowEntries.removeAll { removedSet.contains($0.id) }
      structureChanged = true
    }

    for entry in delta.upserted {
      if let idx = rowEntries.firstIndex(where: { $0.id == entry.id }) {
        rowEntries[idx] = entry
        changed.append(entry)
      } else {
        rowEntries.append(entry)
        changed.append(entry)
        structureChanged = true
      }
    }

    if structureChanged {
      rowEntries.sort { $0.sequence < $1.sequence }
      totalRowCount = max(totalRowCount, UInt64(rowEntries.count))
      structureRevision += 1
    }
    contentRevision += 1
    let appendedEntryCount = structureChanged
      ? changed.reduce(into: 0) { count, entry in
          if entry.sequence > lastNewestSequence {
            count += 1
          }
        }
      : 0
    let visibilityEventRowID = structureChanged
      ? changed.max { lhs, rhs in
          if lhs.sequence == rhs.sequence {
            return lhs.id < rhs.id
          }
          return lhs.sequence < rhs.sequence
        }?.id
      : nil
    rebuildPresentation(
      changedEntries: changed,
      appendedEntryCount: appendedEntryCount,
      visibilityEventRowID: visibilityEventRowID
    )
  }

  func rebuildPresentation(
    changedEntries: [ServerConversationRowEntry],
    appendedEntryCount: Int = 0,
    visibilityEventRowID: String? = nil
  ) {
    let previousNewest = lastNewestSequence
    let timeline = ConversationTimelinePresentation(
      entries: rowEntries,
      contentRevision: contentRevision,
      structureRevision: structureRevision,
      changedEntries: changedEntries
    )

    let nextLoadState: ConversationLoadState = if !rowEntries.isEmpty {
      .ready
    } else if hasShownContent || conversationLoaded {
      .empty
    } else {
      .loading
    }

    let incomingHasTimeline = !rowEntries.isEmpty
    hasTimeline = incomingHasTimeline

    if incomingHasTimeline {
      timelineViewModel.apply(presentation: timeline, viewMode: currentViewMode)

      let requiredVisibleSuffixCount = visibilityEventRowID.flatMap { rowID in
        timelineViewModel.renderWindowRequiredToReveal(rowId: rowID)
      }

      if (appendedEntryCount > 0 && previousNewest > 0) || requiredVisibleSuffixCount != nil {
        latestAppendEvent = ConversationLatestAppendEvent(
          count: appendedEntryCount,
          nonce: (latestAppendEvent?.nonce ?? 0) + 1,
          requiredVisibleSuffixCount: requiredVisibleSuffixCount
        )
      }
      lastNewestSequence = rowEntries.last?.sequence ?? 0
    } else {
      timelineViewModel.clearSession()
      lastNewestSequence = 0
    }

    if loadState != nextLoadState {
      loadState = nextLoadState
    }
  }
}
