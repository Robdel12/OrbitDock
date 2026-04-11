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
enum ClientToServerMessage: Codable, Sendable {
  case subscribeDashboard(sinceRevision: UInt64? = nil)
  case unsubscribeDashboard
  case subscribeMissions(sinceRevision: UInt64? = nil)
  case subscribeSessionSurface(sessionId: String, surface: ServerSessionSurface, sinceRevision: UInt64? = nil)
  case unsubscribeSessionSurface(sessionId: String, surface: ServerSessionSurface)
  case subscribeToolPty(toolId: String, sessionId: String)
  case unsubscribeToolPty(toolId: String)

  enum CodingKeys: String, CodingKey {
    case type
    case sessionId = "session_id"
    case surface
    case sinceRevision = "since_revision"
    case toolId = "tool_id"
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
      case let .subscribeDashboard(sinceRevision):
        try container.encode("subscribe_dashboard", forKey: .type)
        try container.encodeIfPresent(sinceRevision, forKey: .sinceRevision)

      case .unsubscribeDashboard:
        try container.encode("unsubscribe_dashboard", forKey: .type)

      case let .subscribeMissions(sinceRevision):
        try container.encode("subscribe_missions", forKey: .type)
        try container.encodeIfPresent(sinceRevision, forKey: .sinceRevision)

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

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)

    switch type {
      case "subscribe_dashboard":
        self = try .subscribeDashboard(
          sinceRevision: container.decodeIfPresent(UInt64.self, forKey: .sinceRevision)
        )
      case "unsubscribe_dashboard":
        self = .unsubscribeDashboard
      case "subscribe_missions":
        self = try .subscribeMissions(
          sinceRevision: container.decodeIfPresent(UInt64.self, forKey: .sinceRevision)
        )
      case "subscribe_session_surface":
        self = try .subscribeSessionSurface(
          sessionId: container.decode(String.self, forKey: .sessionId),
          surface: container.decode(ServerSessionSurface.self, forKey: .surface),
          sinceRevision: container.decodeIfPresent(UInt64.self, forKey: .sinceRevision)
        )
      case "unsubscribe_session_surface":
        self = try .unsubscribeSessionSurface(
          sessionId: container.decode(String.self, forKey: .sessionId),
          surface: container.decode(ServerSessionSurface.self, forKey: .surface)
        )
      case "subscribe_tool_pty":
        self = try .subscribeToolPty(
          toolId: container.decode(String.self, forKey: .toolId),
          sessionId: container.decode(String.self, forKey: .sessionId)
        )
      case "unsubscribe_tool_pty":
        self = try .unsubscribeToolPty(
          toolId: container.decode(String.self, forKey: .toolId)
        )
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
