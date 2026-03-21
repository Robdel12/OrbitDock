//
//  DirectSessionComposerModel.swift
//  OrbitDock
//
//  Pure input/completion state for DirectSessionComposer.
//

import CoreGraphics
import Foundation

struct DirectSessionComposerState: Equatable {
  var message = ""
  var isSending = false
  var errorMessage: String?
  var pendingRecoveredSendContent: String?
  var pendingRecoveredSendStartedAt: Date?
  var selectedModel = ""
  var selectedClaudeModel = ""
  var selectedEffort: EffortLevel = .default
  var showModelEffortPopover = false
  var showClaudeModelPopover = false
  var showCodexSettingsSheet = false
  var showCodexConfigManagerSheet = false
  var showFilePickerPopover = false
  var filePickerQuery = ""
  var manualReviewMode = false
  var manualShellMode = false
  var dictationDraftBaseMessage: String?
  var showForkToWorktreeSheet = false
  var showForkToExistingWorktreeSheet = false
  var permissionPanelExpanded = false
}

nonisolated enum ComposerInputLoadRequest: Hashable, Sendable {
  case skills
  case projectFiles
  case mcpTools
}

nonisolated enum ComposerCompletionCommand: Sendable {
  case escape
  case upArrow
  case downArrow
  case accept
  case controlN
  case controlP
}

nonisolated struct ComposerSelectionState: Equatable, Sendable {
  var isActive = false
  var query = ""
  var index = 0

  mutating func activate(query: String) {
    self.query = query
    index = 0
    isActive = true
  }

  mutating func dismiss(clearQuery: Bool = true) {
    isActive = false
    index = 0
    if clearQuery {
      query = ""
    }
  }

  mutating func move(_ command: ComposerCompletionCommand, itemCount: Int) -> Bool {
    let maxIndex = itemCount - 1
    guard maxIndex >= 0 else { return false }

    switch command {
      case .upArrow, .controlP:
        index = max(0, index - 1)
        return true
      case .downArrow, .controlN:
        index = min(maxIndex, index + 1)
        return true
      case .accept, .escape:
        return false
    }
  }
}

nonisolated struct ComposerFocusState: Equatable, Sendable {
  var isFocused = false
  var focusRequestSignal = 0
  var blurRequestSignal = 0
  var shouldMaintainTypingFocus = false
  var moveCursorToEndSignal = 0
  var measuredHeight: CGFloat = 30

  mutating func requestFocus() {
    shouldMaintainTypingFocus = true
    focusRequestSignal &+= 1
  }

  mutating func relinquishFocus() {
    shouldMaintainTypingFocus = false
    blurRequestSignal &+= 1
  }

  mutating func moveCursorToEnd() {
    moveCursorToEndSignal &+= 1
  }

  mutating func handle(_ event: ComposerTextAreaFocusEvent, isSessionActive: Bool) -> Bool {
    switch event {
      case .began:
        isFocused = true
        shouldMaintainTypingFocus = true
        return false

      case let .ended(userInitiated):
        isFocused = false
        if userInitiated {
          shouldMaintainTypingFocus = false
          return false
        }
        return shouldMaintainTypingFocus && isSessionActive
    }
  }
}

nonisolated struct DirectSessionComposerInputState: Equatable, Sendable {
  var skillCompletion = ComposerSelectionState()
  var mentionCompletion = ComposerSelectionState()
  var commandDeck = ComposerSelectionState()
  var focus = ComposerFocusState()

  mutating func updateSkillCompletion(
    for text: String,
    availableSkillNames: Set<String>
  ) -> Bool {
    guard let dollarIdx = text.lastIndex(of: "$") else {
      skillCompletion.dismiss()
      return false
    }

    let afterDollar = text[text.index(after: dollarIdx)...]
    guard !afterDollar.contains(where: \.isWhitespace) else {
      skillCompletion.dismiss()
      return false
    }

    let query = String(afterDollar)
    guard !availableSkillNames.contains(query) else {
      skillCompletion.dismiss()
      return false
    }

    skillCompletion.activate(query: query)
    return availableSkillNames.isEmpty
  }

  mutating func updateMentionCompletion(
    for text: String,
    attachedMentions: [AttachedMention]
  ) -> Bool {
    guard let atIdx = text.lastIndex(of: "@") else {
      mentionCompletion.dismiss()
      return false
    }

    if atIdx != text.startIndex {
      let before = text[text.index(before: atIdx)]
      guard before.isWhitespace else {
        mentionCompletion.dismiss()
        return false
      }
    }

    let afterAt = text[text.index(after: atIdx)...]
    guard !afterAt.contains(where: \.isWhitespace) else {
      mentionCompletion.dismiss()
      return false
    }

    let query = String(afterAt)
    guard !attachedMentions.contains(where: { $0.name == query || $0.path.hasSuffix(query) }) else {
      mentionCompletion.dismiss()
      return false
    }

    mentionCompletion.activate(query: query)
    return true
  }

  mutating func updateCommandDeckCompletion(
    for text: String,
    hasSkillsPanel: Bool,
    availableSkillsAreLoaded: Bool,
    hasMcpTools: Bool
  ) -> Set<ComposerInputLoadRequest> {
    guard let slashIdx = text.lastIndex(of: "/") else {
      commandDeck.dismiss()
      return []
    }

    guard isCommandDeckTokenStart(slashIdx, in: text) else {
      commandDeck.dismiss(clearQuery: false)
      return []
    }

    let afterSlash = text[text.index(after: slashIdx)...]
    guard !afterSlash.contains(where: \.isWhitespace) else {
      commandDeck.dismiss(clearQuery: false)
      return []
    }

    commandDeck.activate(query: String(afterSlash))

    var requests: Set<ComposerInputLoadRequest> = [.projectFiles]
    if hasSkillsPanel, !availableSkillsAreLoaded {
      requests.insert(.skills)
    }
    if !hasMcpTools {
      requests.insert(.mcpTools)
    }
    return requests
  }

  mutating func clearCommandDeck() {
    commandDeck.dismiss()
  }

  mutating func dismissMentionCompletion() {
    mentionCompletion.dismiss(clearQuery: false)
  }

  mutating func dismissSkillCompletion() {
    skillCompletion.dismiss(clearQuery: false)
  }

  private func isCommandDeckTokenStart(_ index: String.Index, in text: String) -> Bool {
    if index == text.startIndex {
      return true
    }
    return text[text.index(before: index)].isWhitespace
  }
}
