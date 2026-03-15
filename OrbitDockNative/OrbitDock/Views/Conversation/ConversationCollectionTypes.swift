//
//  ConversationCollectionTypes.swift
//  OrbitDock
//
//  Shared conversation types used across the app.
//

import Foundation

nonisolated struct ConversationJumpTarget: Equatable, Sendable {
  let messageID: String
  let nonce: Int
}

nonisolated enum ApprovalCardMode: Hashable, Sendable {
  case permission
  case question
  case takeover
  case passiveBlocked
  case none
}
