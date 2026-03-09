//
//  ServerSharedTypes.swift
//  OrbitDock
//
//  Shared protocol types and coding helpers.
//

import Foundation

enum ServerProvider: String, Codable {
  case claude
  case codex
}

enum ServerCodexIntegrationMode: String, Codable {
  case direct
  case passive
}

enum ServerClaudeIntegrationMode: String, Codable {
  case direct
  case passive
}

enum ServerTokenUsageSnapshotKind: String, Codable, Hashable, Sendable {
  case unknown
  case contextTurn = "context_turn"
  case lifetimeTotals = "lifetime_totals"
  case mixedLegacy = "mixed_legacy"
  case compactionReset = "compaction_reset"
}

enum ServerShellExecutionOutcome: String, Codable {
  case completed
  case failed
  case timedOut = "timed_out"
  case canceled
}

// MARK: - Skills

struct ServerSkillInput: Codable {
  let name: String
  let path: String
}

// MARK: - Images

struct ServerImageInput: Codable {
  let inputType: String
  let value: String
  let mimeType: String?
  let byteCount: Int?
  let displayName: String?
  let pixelWidth: Int?
  let pixelHeight: Int?

  enum CodingKeys: String, CodingKey {
    case inputType = "input_type"
    case value
    case mimeType = "mime_type"
    case byteCount = "byte_count"
    case displayName = "display_name"
    case pixelWidth = "pixel_width"
    case pixelHeight = "pixel_height"
  }

  init(
    inputType: String,
    value: String,
    mimeType: String? = nil,
    byteCount: Int? = nil,
    displayName: String? = nil,
    pixelWidth: Int? = nil,
    pixelHeight: Int? = nil
  ) {
    self.inputType = inputType
    self.value = value
    self.mimeType = mimeType
    self.byteCount = byteCount
    self.displayName = displayName
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
  }
}

// MARK: - Mentions

struct ServerMentionInput: Codable {
  let name: String
  let path: String
}

/// Wrapper for arbitrary JSON values (used for MCP schemas/annotations)
nonisolated struct AnyCodable: Codable {
  let value: Any

  init(_ value: Any) {
    self.value = value
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let dict = try? container.decode([String: AnyCodable].self) {
      value = dict.mapValues { $0.value }
    } else if let array = try? container.decode([AnyCodable].self) {
      value = array.map(\.value)
    } else if let string = try? container.decode(String.self) {
      value = string
    } else if let int = try? container.decode(Int.self) {
      value = int
    } else if let double = try? container.decode(Double.self) {
      value = double
    } else if let bool = try? container.decode(Bool.self) {
      value = bool
    } else if container.decodeNil() {
      value = NSNull()
    } else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch value {
      case let dict as [String: Any]:
        try container.encode(dict.mapValues { AnyCodable($0) })
      case let array as [Any]:
        try container.encode(array.map { AnyCodable($0) })
      case let string as String:
        try container.encode(string)
      case let int as Int:
        try container.encode(int)
      case let double as Double:
        try container.encode(double)
      case let bool as Bool:
        try container.encode(bool)
      case is NSNull:
        try container.encodeNil()
      default:
        try container.encodeNil()
    }
  }
}
