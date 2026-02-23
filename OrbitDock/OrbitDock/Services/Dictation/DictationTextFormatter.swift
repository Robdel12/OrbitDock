//
//  DictationTextFormatter.swift
//  OrbitDock
//

import Foundation

enum DictationTextFormatter {
  nonisolated static func normalizeTranscription(_ text: String) -> String {
    text
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
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
}
