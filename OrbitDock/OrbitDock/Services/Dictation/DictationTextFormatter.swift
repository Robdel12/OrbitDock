//
//  DictationTextFormatter.swift
//  OrbitDock
//

import Foundation

enum DictationTextFormatter {
  nonisolated static func normalizeTranscription(_ text: String) -> String {
    text
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { token in
        !token.isEmpty && !isIgnorableToken(token)
      }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  nonisolated static func merge(existing: String, dictated: String) -> String {
    let normalizedDictated = normalizeTranscription(dictated)
    guard !normalizedDictated.isEmpty else { return existing }

    let trimmedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedExisting.isEmpty else { return normalizedDictated }

    return "\(trimmedExisting) \(normalizedDictated)"
  }

  private nonisolated static func isIgnorableToken(_ token: String) -> Bool {
    let upper = token.uppercased()
    if upper == "[BLANK_AUDIO]" || upper == "<|BLANK_AUDIO|>" {
      return true
    }

    guard token.hasPrefix("["), token.hasSuffix("]") else {
      return false
    }

    let core = token.dropFirst().dropLast()
    guard !core.isEmpty else { return false }
    return core.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
  }
}
