//
//  DirectSessionComposerActions.swift
//  OrbitDock
//
//  Pure send/can-send planning for DirectSessionComposer.
//

import Foundation

nonisolated enum ComposerProviderMode: Sendable {
  case directCodex
  case directClaude
  case inherited
}

nonisolated enum ComposerSendMode: Sendable {
  case prompt
  case steer
  case reviewNotes
  case shell
}

nonisolated struct DirectSessionComposerSendContext: Sendable {
  let inputMode: ComposerSendMode
  let rawMessage: String
  let hasAttachments: Bool
  let hasMentions: Bool
  let isSending: Bool
  let isConnected: Bool
  let providerMode: ComposerProviderMode
  let selectedCodexModel: String
  let selectedClaudeModel: String
  let inheritedModel: String?
  let effort: String

  var trimmedMessage: String {
    rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var hasContent: Bool {
    !trimmedMessage.isEmpty
  }
}

nonisolated enum DirectSessionComposerSendPlan: Equatable, Sendable {
  case blocked
  case offlineShell(String)
  case missingModel(String)
  case executeShell(command: String, exitsShellMode: Bool)
  case steer(content: String)
  case send(content: String, model: String, effort: String)
}

nonisolated enum DirectSessionComposerActionPlanner {
  static func canSend(_ context: DirectSessionComposerSendContext) -> Bool {
    guard !context.isSending else { return false }

    switch context.inputMode {
      case .shell:
        return context.hasContent

      case .steer:
        return context.hasContent || context.hasAttachments || context.hasMentions

      case .prompt, .reviewNotes:
        guard context.hasContent || context.hasAttachments || context.hasMentions else {
          return false
        }
        switch context.providerMode {
          case .directCodex:
            return !context.selectedCodexModel.isEmpty
          case .directClaude:
            return !context.selectedClaudeModel.isEmpty
          case .inherited:
            return context.inheritedModel != nil
        }
    }
  }

  static func planSend(_ context: DirectSessionComposerSendContext) -> DirectSessionComposerSendPlan {
    guard !context.isSending else { return .blocked }
    guard context.hasContent || context.hasAttachments || context.hasMentions else { return .blocked }

    if case .shell = context.inputMode {
      guard context.isConnected else {
        return .offlineShell("Server is offline. Shell command not sent.")
      }
      return .executeShell(command: context.trimmedMessage, exitsShellMode: true)
    }

    if context.trimmedMessage.hasPrefix("!"), context.trimmedMessage.count > 1 {
      guard context.isConnected else {
        return .offlineShell("Server is offline. Shell command not sent.")
      }
      return .executeShell(command: String(context.trimmedMessage.dropFirst()), exitsShellMode: false)
    }

    if case .steer = context.inputMode {
      guard context.hasContent || context.hasAttachments || context.hasMentions else {
        return .blocked
      }
      return .steer(content: context.trimmedMessage)
    }

    let model: String
    switch context.providerMode {
      case .directCodex:
        guard !context.selectedCodexModel.isEmpty else {
          return .missingModel("No model available yet. Wait for model list to load.")
        }
        model = context.selectedCodexModel
      case .directClaude:
        guard !context.selectedClaudeModel.isEmpty else {
          return .missingModel("No Claude model available yet. Wait for model list to load.")
        }
        model = context.selectedClaudeModel
      case .inherited:
        guard let inheritedModel = context.inheritedModel, !inheritedModel.isEmpty else {
          return .blocked
        }
        model = inheritedModel
    }

    return .send(content: context.trimmedMessage, model: model, effort: context.effort)
  }
}
