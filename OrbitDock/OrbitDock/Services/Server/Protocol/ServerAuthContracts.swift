//
//  ServerAuthContracts.swift
//  OrbitDock
//
//  Authentication and model-selection protocol contracts.
//

import Foundation

// MARK: - Codex Models

struct ServerCodexModelOption: Codable, Identifiable {
  let id: String
  let model: String
  let displayName: String
  let description: String
  let isDefault: Bool
  let supportedReasoningEfforts: [String]
  var supportsReasoningSummaries: Bool? = nil

  enum CodingKeys: String, CodingKey {
    case id
    case model
    case displayName = "display_name"
    case description
    case isDefault = "is_default"
    case supportedReasoningEfforts = "supported_reasoning_efforts"
    case supportsReasoningSummaries = "supports_reasoning_summaries"
  }
}

// MARK: - Claude Models

struct ServerClaudeModelOption: Codable, Identifiable {
  var id: String {
    value
  }

  let value: String
  let displayName: String
  let description: String

  enum CodingKeys: String, CodingKey {
    case value
    case displayName = "display_name"
    case description
  }
}

// MARK: - Codex Account Auth

enum ServerCodexAuthMode: String, Codable {
  case apiKey = "api_key"
  case chatgpt
}

enum ServerCodexAccount: Codable {
  case apiKey
  case chatgpt(email: String?, planType: String?)

  enum CodingKeys: String, CodingKey {
    case type
    case email
    case planType = "plan_type"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
      case "api_key":
        self = .apiKey
      case "chatgpt":
        self = try .chatgpt(
          email: container.decodeIfPresent(String.self, forKey: .email),
          planType: container.decodeIfPresent(String.self, forKey: .planType)
        )
      default:
        throw DecodingError.dataCorrupted(
          DecodingError.Context(
            codingPath: container.codingPath,
            debugDescription: "Unknown codex account type: \(type)"
          )
        )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
      case .apiKey:
        try container.encode("api_key", forKey: .type)
      case let .chatgpt(email, planType):
        try container.encode("chatgpt", forKey: .type)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(planType, forKey: .planType)
    }
  }
}

enum ServerCodexLoginCancelStatus: String, Codable {
  case canceled
  case notFound = "not_found"
  case invalidId = "invalid_id"
}

struct ServerCodexAccountStatus: Codable {
  let authMode: ServerCodexAuthMode?
  let requiresOpenaiAuth: Bool
  let account: ServerCodexAccount?
  let loginInProgress: Bool
  let activeLoginId: String?

  enum CodingKeys: String, CodingKey {
    case authMode = "auth_mode"
    case requiresOpenaiAuth = "requires_openai_auth"
    case account
    case loginInProgress = "login_in_progress"
    case activeLoginId = "active_login_id"
  }
}
