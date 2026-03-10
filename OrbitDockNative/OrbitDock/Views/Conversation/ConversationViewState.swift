//
//  ConversationViewState.swift
//  OrbitDock
//

import Foundation

nonisolated enum ConversationViewLoadState: Equatable, Sendable {
  case loading
  case empty
  case ready
}

struct ConversationViewState: Equatable, Sendable {
  let loadState: ConversationViewLoadState
  let hasMoreMessages: Bool
  let remainingLoadCount: Int
  let totalMessageCount: Int

  static func derive(
    messageCount: Int,
    totalMessageCount: Int,
    hasRenderableConversation: Bool,
    hydrationState: ConversationHydrationState,
    hasMoreHistoryBefore: Bool,
    pageSize: Int
  ) -> ConversationViewState {
    let loadState: ConversationViewLoadState
    if hasRenderableConversation || messageCount > 0 {
      loadState = .ready
    } else {
      switch hydrationState {
        case .empty, .loadingRecent:
          loadState = .loading
        case .readyPartial, .readyComplete, .failed:
          loadState = .empty
      }
    }

    let resolvedTotalMessageCount = max(messageCount, totalMessageCount)
    let remainingLoadCount = min(pageSize, max(0, resolvedTotalMessageCount - messageCount))

    return ConversationViewState(
      loadState: loadState,
      hasMoreMessages: hasMoreHistoryBefore,
      remainingLoadCount: remainingLoadCount,
      totalMessageCount: resolvedTotalMessageCount
    )
  }
}
