//
//  DirectSessionComposerProviderPlanner.swift
//  OrbitDock
//
//  Pure provider/model display and selection rules for DirectSessionComposer.
//

import Foundation

enum DirectSessionComposerProviderPlanner {
  static func activeCodexModelOptions(
    scopedOptions: [ServerCodexModelOption]?,
    fallbackOptions: [ServerCodexModelOption],
    isScopedProviderActive: Bool
  ) -> [ServerCodexModelOption] {
    let normalizedScoped = (scopedOptions ?? []).filter { !$0.model.isEmpty }
    if !normalizedScoped.isEmpty {
      return normalizedScoped
    }
    if isScopedProviderActive {
      return []
    }
    return fallbackOptions
  }

  static func defaultCodexModelSelection(
    currentModel: String?,
    options: [ServerCodexModelOption]
  ) -> String {
    if let currentModel, options.contains(where: { $0.model == currentModel }) {
      return currentModel
    }
    if let model = options.first(where: { $0.isDefault && !$0.model.isEmpty })?.model {
      return model
    }
    return options.first(where: { !$0.model.isEmpty })?.model ?? ""
  }

  static func defaultClaudeModelSelection(
    currentModel: String?,
    options: [ServerClaudeModelOption]
  ) -> String {
    if let currentModel, options.contains(where: { $0.value == currentModel }) {
      return currentModel
    }
    return options.first?.value ?? currentModel ?? ""
  }

  static func effectiveClaudeModel(
    selectedClaudeModel: String,
    sessionModel: String?,
    options: [ServerClaudeModelOption]
  ) -> String {
    if !selectedClaudeModel.isEmpty {
      return selectedClaudeModel
    }
    if let sessionModel, !sessionModel.isEmpty {
      return sessionModel
    }
    return defaultClaudeModelSelection(currentModel: sessionModel, options: options)
  }

  static func hasOverrides(
    providerMode: ComposerProviderMode,
    selectedCodexModel: String?,
    selectedClaudeModel: String,
    currentModel: String?,
    selectedEffort: EffortLevel,
    codexOptions: [ServerCodexModelOption],
    claudeOptions: [ServerClaudeModelOption]
  ) -> Bool {
    switch providerMode {
      case .directCodex:
        let normalizedOverride = selectedCodexModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedCurrentModel = currentModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return selectedEffort != .default
          || (!normalizedOverride.isEmpty && normalizedOverride != normalizedCurrentModel)
      case .directClaude:
        guard !selectedClaudeModel.isEmpty else { return false }
        return selectedClaudeModel
          != defaultClaudeModelSelection(currentModel: currentModel, options: claudeOptions)
      case .inherited:
        return false
    }
  }

  static func compactModelName(_ model: String) -> String {
    let name = model
      .replacingOccurrences(of: "openai/", with: "")
      .replacingOccurrences(of: "anthropic/", with: "")
    if name.count <= 8 {
      return name
    }
    let parts = name.split(separator: "-", maxSplits: 2)
    if parts.count >= 2 {
      return String(parts[0]) + "-" + String(parts[1])
    }
    return name
  }

  static func hasStatusBarContent(
    isConnected: Bool,
    isDirectCodex: Bool,
    isDirectClaude: Bool,
    isSessionWorking: Bool,
    hasTokenUsage: Bool,
    selectedCodexModel: String,
    effectiveClaudeModel: String,
    branch: String?,
    projectPath: String
  ) -> Bool {
    !isConnected
      || isDirectCodex
      || isDirectClaude
      || isSessionWorking
      || hasTokenUsage
      || !selectedCodexModel.isEmpty
      || !effectiveClaudeModel.isEmpty
      || branch != nil
      || !projectPath.isEmpty
  }
}
