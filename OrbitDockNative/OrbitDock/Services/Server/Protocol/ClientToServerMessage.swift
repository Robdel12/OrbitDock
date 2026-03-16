//
//  ClientToServerMessage.swift
//  OrbitDock
//
//  Client-to-server WebSocket message contracts.
//

import Foundation

// MARK: - Client → Server Messages

/// WebSocket-only outbound messages.
/// All reads and mutations go via typed HTTP server clients. Only subscription management uses WS.
enum ClientToServerMessage: Codable {
  case subscribeList
  case subscribeSession(sessionId: String, sinceRevision: UInt64? = nil, includeSnapshot: Bool = true)
  case unsubscribeSession(sessionId: String)

  enum CodingKeys: String, CodingKey {
    case type
    case sessionId = "session_id"
    case sinceRevision = "since_revision"
    case includeSnapshot = "include_snapshot"
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
      case .subscribeList:
        try container.encode("subscribe_list", forKey: .type)

      case let .subscribeSession(sessionId, sinceRevision, includeSnapshot):
        try container.encode("subscribe_session", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(sinceRevision, forKey: .sinceRevision)
        if !includeSnapshot {
          try container.encode(false, forKey: .includeSnapshot)
        }

      case let .unsubscribeSession(sessionId):
        try container.encode("unsubscribe_session", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)

    switch type {
      case "subscribe_list":
        self = .subscribeList
      case "subscribe_session":
        self = try .subscribeSession(
          sessionId: container.decode(String.self, forKey: .sessionId),
          sinceRevision: container.decodeIfPresent(UInt64.self, forKey: .sinceRevision),
          includeSnapshot: container.decodeIfPresent(Bool.self, forKey: .includeSnapshot) ?? true
        )
      case "unsubscribe_session":
        self = try .unsubscribeSession(sessionId: container.decode(String.self, forKey: .sessionId))
      default:
        throw DecodingError.dataCorrupted(
          DecodingError.Context(
            codingPath: container.codingPath,
            debugDescription: "Unknown message type: \(type)"
          )
        )
    }
  }
}
