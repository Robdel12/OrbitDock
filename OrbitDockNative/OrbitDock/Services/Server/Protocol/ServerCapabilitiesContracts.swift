//
//  ServerCapabilitiesContracts.swift
//  OrbitDock
//
//  Skills, MCP, and filesystem browsing protocol contracts.
//

import Foundation

enum ServerSkillScope: String, Codable {
  case user, repo, system, admin
}

struct ServerSkillMetadata: Codable, Identifiable {
  let name: String
  let description: String
  let shortDescription: String?
  let path: String
  let scope: ServerSkillScope
  let enabled: Bool

  var id: String {
    path
  }

  enum CodingKeys: String, CodingKey {
    case name, description, path, scope, enabled
    case shortDescription = "short_description"
  }
}

struct ServerSkillErrorInfo: Codable {
  let path: String
  let message: String
}

struct ServerSkillsListEntry: Codable {
  let cwd: String
  let skills: [ServerSkillMetadata]
  let errors: [ServerSkillErrorInfo]
}

struct ServerRemoteSkillSummary: Codable, Identifiable {
  let id: String
  let name: String
  let description: String
}

// MARK: - MCP Types

struct ServerMcpTool: Codable {
  let name: String
  let title: String?
  let description: String?
  let inputSchema: AnyCodable
  let outputSchema: AnyCodable?
  let annotations: AnyCodable?

  enum CodingKeys: String, CodingKey {
    case name, title, description, annotations
    case inputSchema
    case outputSchema
  }
}

struct ServerMcpResource: Codable {
  let name: String
  let uri: String
  let description: String?
  let mimeType: String?
  let title: String?
  let size: Int64?
  let annotations: AnyCodable?

  enum CodingKeys: String, CodingKey {
    case name, uri, description, title, size, annotations
    case mimeType
  }
}

struct ServerMcpResourceTemplate: Codable {
  let name: String
  let uriTemplate: String
  let title: String?
  let description: String?
  let mimeType: String?
  let annotations: AnyCodable?

  enum CodingKeys: String, CodingKey {
    case name, title, description, annotations
    case uriTemplate
    case mimeType
  }
}

enum ServerMcpAuthStatus: String, Codable {
  case unsupported
  case notLoggedIn = "not_logged_in"
  case bearerToken = "bearer_token"
  case oauth
}

/// Tagged enum matching Rust's `#[serde(tag = "state", rename_all = "snake_case")]`
enum ServerMcpStartupStatus: Codable {
  case starting
  case connecting
  case ready
  case failed(error: String)
  case needsAuth
  case cancelled

  enum CodingKeys: String, CodingKey {
    case state
    case error
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let state = try container.decode(String.self, forKey: .state)
    switch state {
      case "starting": self = .starting
      case "connecting": self = .connecting
      case "ready": self = .ready
      case "failed":
        let error = try container.decode(String.self, forKey: .error)
        self = .failed(error: error)
      case "needs_auth": self = .needsAuth
      case "cancelled": self = .cancelled
      default:
        throw DecodingError.dataCorrupted(
          DecodingError.Context(
            codingPath: container.codingPath,
            debugDescription: "Unknown MCP startup state: \(state)"
          )
        )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
      case .starting:
        try container.encode("starting", forKey: .state)
      case .connecting:
        try container.encode("connecting", forKey: .state)
      case .ready:
        try container.encode("ready", forKey: .state)
      case let .failed(error):
        try container.encode("failed", forKey: .state)
        try container.encode(error, forKey: .error)
      case .needsAuth:
        try container.encode("needs_auth", forKey: .state)
      case .cancelled:
        try container.encode("cancelled", forKey: .state)
    }
  }
}

struct ServerMcpStartupFailure: Codable {
  let server: String
  let error: String
}

// MARK: - Remote Filesystem Browsing

struct ServerDirectoryEntry: Codable, Identifiable {
  let name: String
  let isDir: Bool
  let isGit: Bool

  var id: String {
    name
  }

  enum CodingKeys: String, CodingKey {
    case name
    case isDir = "is_dir"
    case isGit = "is_git"
  }
}

struct ServerRecentProject: Codable, Identifiable {
  let path: String
  let sessionCount: UInt32
  let lastActive: String?

  var id: String {
    path
  }

  enum CodingKeys: String, CodingKey {
    case path
    case sessionCount = "session_count"
    case lastActive = "last_active"
  }
}
