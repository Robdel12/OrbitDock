//
//  ConversationTimelineReducer.swift
//  OrbitDock
//
//  Pure reducer for conversation timeline source/UI state transitions.
//

import CoreGraphics
import Foundation

nonisolated enum ConversationTimelineAction: Sendable {
  case setMessages([TranscriptMessage])
  case appendMessages([TranscriptMessage])
  case prependMessages([TranscriptMessage])
  case setTurns([TurnSummary])
  case setSessionMetadata(ConversationSourceState.SessionMetadata)
  case toggleToolCard(String)
  case toggleRollup(String)
  case toggleMarkdown(String)
  case setPinnedToBottom(Bool)
  case setScrollAnchor(ConversationUIState.ScrollAnchor?)
  case widthChanged(CGFloat)
}

nonisolated enum ConversationTimelineReducer {
  static func reducing(
    source: ConversationSourceState,
    ui: ConversationUIState,
    action: ConversationTimelineAction
  ) -> (source: ConversationSourceState, ui: ConversationUIState) {
    var nextSource = source
    var nextUI = ui
    reduce(source: &nextSource, ui: &nextUI, action: action)
    return (nextSource, nextUI)
  }

  static func reduce(
    source: inout ConversationSourceState,
    ui: inout ConversationUIState,
    action: ConversationTimelineAction
  ) {
    switch action {
      case let .setMessages(messages):
        source.messages = messages

      case let .appendMessages(messages):
        guard !messages.isEmpty else { return }
        source.messages.append(contentsOf: messages)

      case let .prependMessages(messages):
        guard !messages.isEmpty else { return }
        source.messages.insert(contentsOf: messages, at: 0)

      case let .setTurns(turns):
        source.turns = turns

      case let .setSessionMetadata(metadata):
        source.metadata = metadata

      case let .toggleToolCard(id):
        toggle(id, in: &ui.expandedToolCards)

      case let .toggleRollup(id):
        toggle(id, in: &ui.expandedRollups)

      case let .toggleMarkdown(id):
        toggle(id, in: &ui.expandedMarkdownBlocks)

      case let .setPinnedToBottom(isPinned):
        ui.isPinnedToBottom = isPinned

      case let .setScrollAnchor(anchor):
        ui.scrollAnchor = anchor

      case let .widthChanged(width):
        ui.widthBucket = widthBucket(for: width)
    }
  }

  private static func toggle(_ id: String, in set: inout Set<String>) {
    if set.contains(id) {
      set.remove(id)
    } else {
      set.insert(id)
    }
  }

  static func widthBucket(for width: CGFloat) -> Int {
    max(1, Int((width / 24).rounded(.toNearestOrAwayFromZero)))
  }
}
