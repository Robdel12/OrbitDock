//
//  ModelCatalog.swift
//  OrbitDock
//
//  Client-side pretty-printing for model IDs. Turns raw identifiers like
//  "gpt-5.2-codex" or "claude-opus-4-6" into display metadata (family, tint)
//  for the control-deck model picker.
//
//  All derivation happens on the client — the server only ships raw IDs.
//

import SwiftUI

// MARK: - Family

enum ModelFamily: String, CaseIterable, Hashable, Sendable {
  case claude = "Claude"
  case gpt = "GPT"
  case gemini = "Gemini"
  case other = "Other"

  var tint: Color {
    switch self {
      case .claude: .providerClaude
      case .gpt: .providerCodex
      case .gemini: .providerGemini
      case .other: .textTertiary
    }
  }

  /// Display order in the grouped picker.
  var sortRank: Int {
    switch self {
      case .claude: 0
      case .gpt: 1
      case .gemini: 2
      case .other: 3
    }
  }
}

// MARK: - Descriptor

struct ModelDescriptor: Identifiable, Hashable, Sendable {
  /// Raw model identifier from the server.
  let id: String
  /// Pretty display name, e.g. "GPT-5.2 Codex" or "Opus 4.6".
  let displayName: String
  let family: ModelFamily
  /// Family- or tier-specific color, used for the pill icon and the selected checkmark.
  let tint: Color
}

// MARK: - Catalog

enum ModelCatalog {
  /// Returns a descriptor for a raw model id, or `nil` when empty.
  static func describe(_ model: String?) -> ModelDescriptor? {
    guard let raw = model?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }

    if let curated = curated[raw] { return curated }

    let lowered = raw.lowercased()
    let family = detectFamily(lowered)
    let tint = detectTint(lowered, family: family)
    let displayName = formatDisplayName(raw, family: family)

    return ModelDescriptor(
      id: raw,
      displayName: displayName,
      family: family,
      tint: tint
    )
  }

  /// Group an ordered list of raw model ids by family, preserving order within each family.
  static func grouped(_ models: [String]) -> [ModelFamilyGroup] {
    var seen = Set<String>()
    var byFamily: [ModelFamily: [ModelDescriptor]] = [:]

    for model in models {
      guard seen.insert(model).inserted else { continue }
      guard let descriptor = describe(model) else { continue }
      byFamily[descriptor.family, default: []].append(descriptor)
    }

    return byFamily
      .sorted { $0.key.sortRank < $1.key.sortRank }
      .map { ModelFamilyGroup(family: $0.key, descriptors: $0.value) }
  }

  // MARK: - Internals

  /// Curated pretty names for models we know by heart.
  private static let curated: [String: ModelDescriptor] = [
    "claude-opus-4-6": ModelDescriptor(
      id: "claude-opus-4-6",
      displayName: "Opus 4.6",
      family: .claude,
      tint: .modelOpus
    ),
    "claude-sonnet-4-6": ModelDescriptor(
      id: "claude-sonnet-4-6",
      displayName: "Sonnet 4.6",
      family: .claude,
      tint: .modelSonnet
    ),
    "claude-haiku-4-5": ModelDescriptor(
      id: "claude-haiku-4-5",
      displayName: "Haiku 4.5",
      family: .claude,
      tint: .modelHaiku
    ),
  ]

  private static func detectFamily(_ lowered: String) -> ModelFamily {
    if lowered.hasPrefix("claude") { return .claude }
    if lowered.hasPrefix("gpt") || lowered.contains("codex") { return .gpt }
    if lowered.hasPrefix("gemini") { return .gemini }
    return .other
  }

  private static func detectTint(_ lowered: String, family: ModelFamily) -> Color {
    switch family {
      case .claude:
        if lowered.contains("opus") { return .modelOpus }
        if lowered.contains("sonnet") { return .modelSonnet }
        if lowered.contains("haiku") { return .modelHaiku }
        return .providerClaude
      default:
        return family.tint
    }
  }

  private static func formatDisplayName(_ raw: String, family: ModelFamily) -> String {
    // Strip trailing date tags like "-20251001" so display is stable across model refreshes.
    let dateless = raw.replacingOccurrences(
      of: #"-\d{6,}$"#,
      with: "",
      options: .regularExpression
    )

    switch family {
      case .gpt:
        // "gpt-5.2-codex" → "GPT-5.2 Codex"
        let parts = dateless.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return dateless.uppercased() }
        let rest = parts[1]
          .split(separator: "-")
          .map { titleCase(String($0)) }
          .joined(separator: " ")
        return "\(parts[0].uppercased())-\(rest)"
      case .claude:
        // "claude-opus-4-6" → "Opus 4.6"
        let trimmed = dateless.replacingOccurrences(of: "claude-", with: "")
        let parts = trimmed.split(separator: "-").map(String.init)
        guard let name = parts.first else { return titleCase(trimmed) }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? titleCase(name) : "\(titleCase(name)) \(version)"
      case .gemini:
        let trimmed = dateless.replacingOccurrences(of: "gemini-", with: "")
        let pretty = trimmed
          .split(separator: "-")
          .map { titleCase(String($0)) }
          .joined(separator: " ")
        return "Gemini \(pretty)"
      case .other:
        return dateless
          .split(separator: "-")
          .map { titleCase(String($0)) }
          .joined(separator: " ")
    }
  }

  /// Preserves numeric tokens (3, 4.6) and only capitalizes alpha-only segments.
  private static func titleCase(_ s: String) -> String {
    guard !s.isEmpty else { return s }
    if s.contains(where: { $0.isNumber }) { return s }
    return s.prefix(1).uppercased() + s.dropFirst().lowercased()
  }
}

// MARK: - Grouping

struct ModelFamilyGroup: Identifiable, Hashable {
  let family: ModelFamily
  let descriptors: [ModelDescriptor]

  var id: ModelFamily { family }
}
