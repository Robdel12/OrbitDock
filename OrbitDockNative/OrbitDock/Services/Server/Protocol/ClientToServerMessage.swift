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
enum ClientToServerMessage: Encodable, Sendable {
  case subscribeSessionsSummary(sinceRevision: UInt64? = nil)
  case unsubscribeSessionsSummary
  case subscribeActiveSessions(sinceRevision: UInt64? = nil)
  case unsubscribeActiveSessions
  case subscribeArchivedSessions(sinceRevision: UInt64? = nil)
  case unsubscribeArchivedSessions
  case subscribeMissions(sinceRevision: UInt64? = nil)
  case unsubscribeMissions
  case subscribeMission(missionId: String)
  case unsubscribeMission(missionId: String)
  case subscribeSessionSurface(sessionId: String, surface: ServerSessionSurface, sinceRevision: UInt64? = nil)
  case unsubscribeSessionSurface(sessionId: String, surface: ServerSessionSurface)
  case subscribeToolPty(toolId: String, sessionId: String)
  case unsubscribeToolPty(toolId: String)

  enum CodingKeys: String, CodingKey {
    case type
    case sessionId = "session_id"
    case missionId = "mission_id"
    case surface
    case sinceRevision = "since_revision"
    case toolId = "tool_id"
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
      case let .subscribeSessionsSummary(sinceRevision):
        try container.encode("subscribe_sessions_summary", forKey: .type)
        try container.encodeIfPresent(sinceRevision, forKey: .sinceRevision)

      case .unsubscribeSessionsSummary:
        try container.encode("unsubscribe_sessions_summary", forKey: .type)

      case let .subscribeActiveSessions(sinceRevision):
        try container.encode("subscribe_active_sessions", forKey: .type)
        try container.encodeIfPresent(sinceRevision, forKey: .sinceRevision)

      case .unsubscribeActiveSessions:
        try container.encode("unsubscribe_active_sessions", forKey: .type)

      case let .subscribeArchivedSessions(sinceRevision):
        try container.encode("subscribe_archived_sessions", forKey: .type)
        try container.encodeIfPresent(sinceRevision, forKey: .sinceRevision)

      case .unsubscribeArchivedSessions:
        try container.encode("unsubscribe_archived_sessions", forKey: .type)

      case let .subscribeMissions(sinceRevision):
        try container.encode("subscribe_missions", forKey: .type)
        try container.encodeIfPresent(sinceRevision, forKey: .sinceRevision)

      case .unsubscribeMissions:
        try container.encode("unsubscribe_missions", forKey: .type)

      case let .subscribeMission(missionId):
        try container.encode("subscribe_mission", forKey: .type)
        try container.encode(missionId, forKey: .missionId)

      case let .unsubscribeMission(missionId):
        try container.encode("unsubscribe_mission", forKey: .type)
        try container.encode(missionId, forKey: .missionId)

      case let .subscribeSessionSurface(sessionId, surface, sinceRevision):
        try container.encode("subscribe_session_surface", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(surface, forKey: .surface)
        try container.encodeIfPresent(sinceRevision, forKey: .sinceRevision)

      case let .unsubscribeSessionSurface(sessionId, surface):
        try container.encode("unsubscribe_session_surface", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(surface, forKey: .surface)

      case let .subscribeToolPty(toolId, sessionId):
        try container.encode("subscribe_tool_pty", forKey: .type)
        try container.encode(toolId, forKey: .toolId)
        try container.encode(sessionId, forKey: .sessionId)

      case let .unsubscribeToolPty(toolId):
        try container.encode("unsubscribe_tool_pty", forKey: .type)
        try container.encode(toolId, forKey: .toolId)
    }
  }
}
