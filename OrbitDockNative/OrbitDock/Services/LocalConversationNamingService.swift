//
//  LocalConversationNamingService.swift
//  OrbitDock
//
//  On-device conversation naming via Apple Foundation Models.
//  Generates concise session titles without requiring an OpenAI API key.
//

import Foundation
#if canImport(FoundationModels)
  import FoundationModels
#endif

typealias LocalConversationTitleGenerator = @Sendable (LocalConversationNamingContext) async -> String?

struct LocalConversationNamingContext: Equatable, Sendable {
  let firstPrompt: String
  let projectName: String?
  let projectPath: String?

  var projectLeaf: String? {
    guard let projectPath else { return nil }
    let leaf = URL(fileURLWithPath: projectPath).lastPathComponent
    let cleaned = LocalConversationNamingPlanner.cleanDisplayText(leaf)
    return cleaned.isEmpty ? nil : cleaned
  }
}

struct LocalConversationNamingSessionState: Equatable, Sendable {
  var customName: String?
  var summary: String?
  var firstPrompt: String?
  var projectName: String?
  var projectPath: String?

  init(
    customName: String? = nil,
    summary: String? = nil,
    firstPrompt: String? = nil,
    projectName: String? = nil,
    projectPath: String? = nil
  ) {
    self.customName = LocalConversationNamingPlanner.cleanOptionalText(customName)
    self.summary = LocalConversationNamingPlanner.cleanOptionalText(summary)
    self.firstPrompt = LocalConversationNamingPlanner.cleanOptionalText(firstPrompt)
    self.projectName = LocalConversationNamingPlanner.cleanOptionalText(projectName)
    self.projectPath = LocalConversationNamingPlanner.cleanOptionalText(projectPath)
  }

  init(session: ServerSessionState) {
    self.init(
      customName: session.customName,
      summary: session.summary,
      firstPrompt: session.firstPrompt,
      projectName: session.projectName,
      projectPath: session.projectPath
    )
  }

  func applying(_ changes: ServerStateChanges) -> LocalConversationNamingSessionState {
    var updated = self

    if let customName = changes.customName {
      updated.customName = LocalConversationNamingPlanner.cleanOptionalText(customName ?? nil)
    }
    if let summary = changes.summary {
      updated.summary = LocalConversationNamingPlanner.cleanOptionalText(summary ?? nil)
    }
    if let firstPrompt = changes.firstPrompt {
      updated.firstPrompt = LocalConversationNamingPlanner.cleanOptionalText(firstPrompt ?? nil)
    }

    return updated
  }

  nonisolated var hasResolvedTitle: Bool {
    LocalConversationNamingPlanner.hasMeaningfulText(customName)
      || LocalConversationNamingPlanner.hasMeaningfulText(summary)
  }
}

enum LocalConversationNamingDecision: Equatable {
  case skip(claimSession: Bool)
  case generate(LocalConversationNamingContext)
}

nonisolated enum LocalConversationNamingPlanner {
  private static let bootstrapPromptMarkers = [
    "<environment_context>",
    "<permissions instructions>",
    "<collaboration_mode>",
    "<skill>",
    "<turn_aborted>",
    "the user interrupted the previous turn on purpose",
    "agents.md instructions for",
  ]

  static func decision(
    prompt: String,
    sessionState: LocalConversationNamingSessionState?
  ) -> LocalConversationNamingDecision {
    guard let normalizedInputPrompt = normalizedPrompt(prompt),
          !isBootstrapPrompt(normalizedInputPrompt)
    else {
      return .skip(claimSession: false)
    }

    guard let sessionState else { return .skip(claimSession: false) }
    guard !sessionState.hasResolvedTitle else {
      return .skip(claimSession: true)
    }

    let authoritativeFirstPrompt = normalizedPrompt(sessionState.firstPrompt) ?? normalizedInputPrompt
    guard authoritativeFirstPrompt == normalizedInputPrompt else {
      return .skip(claimSession: true)
    }

    return .generate(LocalConversationNamingContext(
      firstPrompt: authoritativeFirstPrompt,
      projectName: cleanOptionalText(sessionState.projectName),
      projectPath: cleanOptionalText(sessionState.projectPath)
    ))
  }

  static func normalizedPrompt(_ value: String?) -> String? {
    guard let cleaned = cleanOptionalText(value) else { return nil }
    let collapsed = cleaned
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    return collapsed.isEmpty ? nil : collapsed
  }

  static func cleanOptionalText(_ value: String?) -> String? {
    guard let value else { return nil }
    let cleaned = cleanDisplayText(value)
    return cleaned.isEmpty ? nil : cleaned
  }

  static func cleanDisplayText(_ value: String) -> String {
    value
      .strippingXMLTags()
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func hasMeaningfulText(_ value: String?) -> Bool {
    cleanOptionalText(value) != nil
  }

  static func isBootstrapPrompt(_ value: String) -> Bool {
    let lower = value.lowercased()
    return bootstrapPromptMarkers.contains { lower.contains($0) }
  }

  static func matchesProjectLabel(_ title: String, projectName: String?, projectLeaf: String?) -> Bool {
    let normalizedTitle = normalizedLabel(title)
    guard !normalizedTitle.isEmpty else { return false }

    return normalizedProjectLabels(projectName: projectName, projectLeaf: projectLeaf)
      .contains(normalizedTitle)
  }

  private static func normalizedLabel(_ value: String) -> String {
    value
      .lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private static func normalizedProjectLabels(
    projectName: String?,
    projectLeaf: String?
  ) -> [String] {
    [projectName, projectLeaf]
      .compactMap(cleanOptionalText)
      .map(normalizedLabel)
      .filter { !$0.isEmpty }
  }
}

nonisolated enum LocalNamingAvailability: Equatable, Sendable {
  case available
  case unavailable
}

nonisolated enum LocalNamingAvailabilityResolver {
  static var current: LocalNamingAvailability {
    #if canImport(FoundationModels)
      if #available(macOS 26.0, iOS 26.0, *) {
        return SystemLanguageModel.default.availability == .available ? .available : .unavailable
      }
    #endif
    return .unavailable
  }
}

#if canImport(FoundationModels)
  @available(macOS 26.0, iOS 26.0, *)
  @Generable(description: "A concise conversation title")
  struct GeneratedSessionTitle {
    @Guide(
      description: "A concise 2-6 word coding-session title. Title case. Specific. No quotes. No trailing punctuation. Avoid filler like Help, Investigate, Please, or project-name-only labels."
    )
    var name: String
  }

  @available(macOS 26.0, iOS 26.0, *)
  enum LocalConversationNamingService {
    private static let instructions = Instructions {
      """
      You name coding sessions for a developer tool.

      You will receive:
      - the user's first prompt
      - optional project context

      Produce one concise, specific title for the session.

      Rules:
      - Prefer the concrete task, bug, feature, or subsystem
      - Use project context only when it adds useful specificity
      - Do not just repeat the project name or repo name
      - Drop conversational filler like "Can you help me", "Please", or "I need to"
      - Avoid vague titles like "New Conversation", "Debug Issue", or "Code Help"
      - Keep it short, natural, and scannable
      - Use title case
      - No quotes
      - No trailing punctuation

      Good examples:
      - Fix Apple Session Title Resets
      - Tighten Session Naming Logic
      - Refactor Dashboard Recovery Flow
      - OrbitDock Prompt Title Generation

      Bad examples:
      - New Conversation
      - OrbitDock
      - Help With Session Bug
      """
    }

    static func generateTitle(from context: LocalConversationNamingContext) async -> String? {
      guard SystemLanguageModel.default.availability == .available else { return nil }

      let prompt = context.firstPrompt
      let truncatedPrompt = prompt.count > 500 ? String(prompt.prefix(500)) : prompt
      let namingInput = makeNamingInput(
        firstPrompt: truncatedPrompt,
        projectName: context.projectName,
        projectLeaf: context.projectLeaf
      )

      do {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
          to: namingInput,
          generating: GeneratedSessionTitle.self
        )
        return sanitizeGeneratedTitle(
          response.content.name,
          projectName: context.projectName,
          projectLeaf: context.projectLeaf
        )
      } catch {
        return nil
      }
    }

    private static func makeNamingInput(
      firstPrompt: String,
      projectName: String?,
      projectLeaf: String?
    ) -> String {
      var lines = ["First user prompt:", firstPrompt]
      appendContextSection("Project name:", value: projectName, to: &lines)
      appendContextSection("Project folder:", value: projectLeaf, to: &lines)
      return lines.joined(separator: "\n")
    }

    private static func sanitizeGeneratedTitle(
      _ rawValue: String,
      projectName: String?,
      projectLeaf: String?
    ) -> String? {
      let collapsed = rawValue
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
      var cleaned = collapsed
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

      while let last = cleaned.last, ".!,?:;".contains(last) {
        cleaned.removeLast()
      }

      guard !cleaned.isEmpty else { return nil }

      if LocalConversationNamingPlanner.matchesProjectLabel(
        cleaned,
        projectName: projectName,
        projectLeaf: projectLeaf
      ) {
        return nil
      }

      if cleaned.count > 48 {
        cleaned = String(cleaned.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
      }

      return cleaned.isEmpty ? nil : cleaned
    }

    private static func appendContextSection(
      _ title: String,
      value: String?,
      to lines: inout [String]
    ) {
      guard let value = LocalConversationNamingPlanner.cleanOptionalText(value) else { return }
      lines.append("")
      lines.append(title)
      lines.append(value)
    }
  }
#endif
