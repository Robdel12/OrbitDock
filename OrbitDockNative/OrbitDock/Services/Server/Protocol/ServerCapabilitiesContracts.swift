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

struct ServerSkillInterface: Codable {
  let displayName: String?
  let shortDescription: String?
  let iconSmall: String?
  let iconLarge: String?
  let brandColor: String?
  let defaultPrompt: String?

  enum CodingKeys: String, CodingKey {
    case displayName = "display_name"
    case shortDescription = "short_description"
    case iconSmall = "icon_small"
    case iconLarge = "icon_large"
    case brandColor = "brand_color"
    case defaultPrompt = "default_prompt"
  }
}

struct ServerSkillToolDependency: Codable, Identifiable {
  let type: String
  let value: String
  let description: String?
  let transport: String?
  let command: String?
  let url: String?

  var id: String {
    [type, value, transport ?? "", command ?? "", url ?? ""].joined(separator: "|")
  }
}

struct ServerSkillDependencies: Codable {
  let tools: [ServerSkillToolDependency]
}

struct ServerSkillMetadata: Codable, Identifiable {
  let name: String
  let description: String
  let shortDescription: String?
  let interface: ServerSkillInterface?
  let dependencies: ServerSkillDependencies?
  let path: String
  let scope: ServerSkillScope
  let enabled: Bool

  var id: String {
    path
  }

  enum CodingKeys: String, CodingKey {
    case name, description, interface, dependencies, path, scope, enabled
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

// MARK: - Plugins

enum ServerPluginSource: Codable {
  case local(path: String)
  case git(url: String, path: String?, refName: String?, sha: String?)
  case remote

  enum CodingKeys: String, CodingKey {
    case type
    case path
    case url
    case refName = "ref_name"
    case sha
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .type) {
      case "local":
        self = .local(path: try container.decode(String.self, forKey: .path))
      case "git":
        self = .git(
          url: try container.decode(String.self, forKey: .url),
          path: try container.decodeIfPresent(String.self, forKey: .path),
          refName: try container.decodeIfPresent(String.self, forKey: .refName),
          sha: try container.decodeIfPresent(String.self, forKey: .sha)
        )
      case "remote":
        self = .remote
      default:
        throw DecodingError.dataCorrupted(
          .init(codingPath: decoder.codingPath, debugDescription: "Unsupported plugin source")
        )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
      case let .local(path):
        try container.encode("local", forKey: .type)
        try container.encode(path, forKey: .path)
      case let .git(url, path, refName, sha):
        try container.encode("git", forKey: .type)
        try container.encode(url, forKey: .url)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(refName, forKey: .refName)
        try container.encodeIfPresent(sha, forKey: .sha)
      case .remote:
        try container.encode("remote", forKey: .type)
    }
  }
}

enum ServerPluginInstallPolicy: String, Codable {
  case notAvailable = "NOT_AVAILABLE"
  case available = "AVAILABLE"
  case installedByDefault = "INSTALLED_BY_DEFAULT"
}

enum ServerPluginAuthPolicy: String, Codable {
  case onInstall = "ON_INSTALL"
  case onUse = "ON_USE"
}

struct ServerPluginInterface: Codable {
  let displayName: String?
  let shortDescription: String?
  let longDescription: String?
  let developerName: String?
  let category: String?
  let capabilities: [String]
  let websiteURL: String?
  let privacyPolicyURL: String?
  let termsOfServiceURL: String?
  let defaultPrompt: [String]?
  let brandColor: String?
  let composerIcon: String?
  let composerIconURL: String?
  let logo: String?
  let logoURL: String?
  let screenshots: [String]
  let screenshotURLs: [String]

  enum CodingKeys: String, CodingKey {
    case displayName = "display_name"
    case shortDescription = "short_description"
    case longDescription = "long_description"
    case developerName = "developer_name"
    case category
    case capabilities
    case websiteURL = "website_url"
    case privacyPolicyURL = "privacy_policy_url"
    case termsOfServiceURL = "terms_of_service_url"
    case defaultPrompt = "default_prompt"
    case brandColor = "brand_color"
    case composerIcon = "composer_icon"
    case composerIconURL = "composer_icon_url"
    case logo
    case logoURL = "logo_url"
    case screenshots
    case screenshotURLs = "screenshot_urls"
  }
}

struct ServerPluginSummary: Codable, Identifiable {
  let id: String
  let name: String
  let source: ServerPluginSource
  let installed: Bool
  let enabled: Bool
  let installPolicy: ServerPluginInstallPolicy
  let authPolicy: ServerPluginAuthPolicy
  let interface: ServerPluginInterface?

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case source
    case installed
    case enabled
    case installPolicy = "install_policy"
    case authPolicy = "auth_policy"
    case interface
  }
}

struct ServerPluginMarketplaceInterface: Codable {
  let displayName: String?

  enum CodingKeys: String, CodingKey {
    case displayName = "display_name"
  }
}

struct ServerPluginMarketplaceEntry: Codable, Identifiable {
  let name: String
  let path: String?
  let interface: ServerPluginMarketplaceInterface?
  let plugins: [ServerPluginSummary]

  var id: String {
    name
  }
}

struct ServerPluginMarketplaceLoadError: Codable, Identifiable {
  let marketplacePath: String
  let message: String

  var id: String {
    marketplacePath
  }

  enum CodingKeys: String, CodingKey {
    case marketplacePath = "marketplace_path"
    case message
  }
}

struct ServerPluginAppSummary: Codable, Identifiable {
  let id: String
  let name: String
  let description: String?
  let installURL: String?
  let needsAuth: Bool

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case description
    case installURL = "install_url"
    case needsAuth = "needs_auth"
  }
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

enum ServerMcpAuthStatus: Codable, Equatable {
  case unsupported
  case notLoggedIn
  case bearerToken
  case oauth

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)

    switch rawValue {
    case "unsupported":
      self = .unsupported
    case "not_logged_in", "notLoggedIn":
      self = .notLoggedIn
    case "bearer_token", "bearerToken":
      self = .bearerToken
    case "oauth", "oAuth", "o_auth":
      self = .oauth
    default:
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported MCP auth status: \(rawValue)"
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()

    switch self {
    case .unsupported:
      try container.encode("unsupported")
    case .notLoggedIn:
      try container.encode("not_logged_in")
    case .bearerToken:
      try container.encode("bearer_token")
    case .oauth:
      try container.encode("oauth")
    }
  }
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
