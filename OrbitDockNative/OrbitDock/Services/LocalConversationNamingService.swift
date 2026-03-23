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
    @Guide(description: "A concise 3-7 word title for this coding session. Title case. No quotes. No trailing punctuation.")
    var name: String
  }

  @available(macOS 26.0, iOS 26.0, *)
  enum LocalConversationNamingService {
    private static let instructions = Instructions {
      """
      You name coding sessions. Given a user's first message to an AI coding assistant, \
      produce a concise 3-7 word title for the conversation.

      Rules:
      - Use title case
      - No quotes around the title
      - No trailing punctuation
      - Avoid generic titles like "New Conversation" or project-name-only labels
      - Focus on the intent or topic of the user's message
      """
    }

    static func generateTitle(from prompt: String) async -> String? {
      guard SystemLanguageModel.default.availability == .available else { return nil }

      let truncated = prompt.count > 500 ? String(prompt.prefix(500)) : prompt

      do {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
          to: truncated,
          generating: GeneratedSessionTitle.self
        )
        let name = response.content.name
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        guard !name.isEmpty else { return nil }
        return name
      } catch {
        return nil
      }
    }
  }
#endif
