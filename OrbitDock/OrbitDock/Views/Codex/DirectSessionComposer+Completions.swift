//
//  DirectSessionComposer+Completions.swift
//  OrbitDock
//
//  Inline completion logic (skills, mentions, command deck) and keyboard navigation.
//

import SwiftUI

extension DirectSessionComposer {
  // MARK: - Inline Skill Completion

  func updateSkillCompletion(_ text: String) {
    guard let dollarIdx = text.lastIndex(of: "$") else {
      completionActive = false
      return
    }

    let afterDollar = text[text.index(after: dollarIdx)...]

    if afterDollar.contains(where: \.isWhitespace) {
      completionActive = false
      return
    }

    let query = String(afterDollar)

    if availableSkills.contains(where: { $0.name == query }) {
      completionActive = false
      return
    }

    if availableSkills.isEmpty {
      serverState.listSkills(sessionId: sessionId)
    }

    completionQuery = query
    completionIndex = 0
    completionActive = true
  }

  func acceptSkillCompletion(_ skill: ServerSkillMetadata) {
    if let updated = ComposerTextEditing.applySkillCompletion(in: message, skillName: skill.name) {
      setComposerMessage(updated, moveCursorToEnd: true)
    }
    completionActive = false
    completionQuery = ""
    completionIndex = 0
    requestComposerFocus()
  }

  func extractInlineSkillNames(from text: String) -> [String] {
    let skillNameSet = Set(availableSkills.map(\.name))
    var names: [String] = []

    for word in text.components(separatedBy: .whitespacesAndNewlines) {
      guard word.hasPrefix("$") else { continue }
      let raw = String(word.dropFirst())
      let name = raw.trimmingCharacters(in: .punctuationCharacters)
      if skillNameSet.contains(name) {
        names.append(name)
      }
    }

    return names
  }

  // MARK: - @ Mention Completion

  func updateMentionCompletion(_ text: String) {
    guard let atIdx = text.lastIndex(of: "@") else {
      mentionActive = false
      return
    }

    if atIdx != text.startIndex {
      let before = text[text.index(before: atIdx)]
      if !before.isWhitespace {
        mentionActive = false
        return
      }
    }

    let afterAt = text[text.index(after: atIdx)...]

    if afterAt.contains(where: \.isWhitespace) {
      mentionActive = false
      return
    }

    let query = String(afterAt)

    if attachedMentions.contains(where: { $0.name == query || $0.path.hasSuffix(query) }) {
      mentionActive = false
      return
    }

    mentionQuery = query
    mentionIndex = 0
    mentionActive = true

    loadProjectFilesIfNeeded()
  }

  func acceptMentionCompletion(_ file: ProjectFileIndex.ProjectFile) {
    if let updated = ComposerTextEditing.applyMentionCompletion(in: message, fileName: file.name) {
      setComposerMessage(updated, moveCursorToEnd: true)
    }
    mentionActive = false
    mentionQuery = ""
    mentionIndex = 0
    requestComposerFocus()

    addMentionAttachment(file)
    Platform.services.playHaptic(.selection)
  }

  func addMentionAttachment(_ file: ProjectFileIndex.ProjectFile) {
    guard !attachedMentions.contains(where: { $0.id == file.id }) else { return }
    let absolutePath = if let base = projectPath {
      (base as NSString).appendingPathComponent(file.relativePath)
    } else {
      file.relativePath
    }
    withAnimation(Motion.gentle) {
      attachedMentions.append(AttachedMention(id: file.id, name: file.name, path: absolutePath))
    }
  }

  func attachMentionFromPicker(_ file: ProjectFileIndex.ProjectFile) {
    replaceTrailingCommandDeckToken(with: "@\(file.name)")
    addMentionAttachment(file)
    showFilePickerPopover = false
    clearCommandDeckState()
    requestComposerFocus()
    Platform.services.playHaptic(.selection)
  }

  func openFilePicker() {
    guard projectPath != nil else {
      errorMessage = "No project path available for this session."
      Platform.services.playHaptic(.error)
      return
    }
    filePickerQuery = ""
    loadProjectFilesIfNeeded()
    showFilePickerPopover = true
    Platform.services.playHaptic(.selection)
  }

  // MARK: - Command Deck

  func updateCommandDeckCompletion(_ text: String) {
    guard let slashIdx = text.lastIndex(of: "/") else {
      commandDeckActive = false
      commandDeckQuery = ""
      commandDeckIndex = 0
      return
    }

    guard ComposerTextEditing.isCommandDeckTokenStart(slashIdx, in: text) else {
      commandDeckActive = false
      return
    }

    let afterSlash = text[text.index(after: slashIdx)...]
    if afterSlash.contains(where: \.isWhitespace) {
      commandDeckActive = false
      return
    }

    commandDeckQuery = String(afterSlash)
    commandDeckIndex = 0
    commandDeckActive = true

    if hasSkillsPanel, availableSkills.isEmpty {
      serverState.listSkills(sessionId: sessionId)
    }
    if serverState.session(sessionId).mcpTools.isEmpty {
      serverState.listMcpTools(sessionId: sessionId)
    }
    loadProjectFilesIfNeeded()
  }

  func loadProjectFilesIfNeeded() {
    guard let path = projectPath, !fileIndex.isReady(for: path) else { return }
    Task { @MainActor in
      await fileIndex.loadIfNeeded(path)
    }
  }

  func toggleCommandDeck() {
    if shouldShowCommandDeck {
      clearCommandDeckState()
      removeTrailingCommandDeckToken()
      Platform.services.playHaptic(.selection)
      return
    }
    activateCommandDeck()
  }

  func activateCommandDeck(prefill: String? = nil) {
    let updated = ComposerTextEditing.activateCommandDeckToken(in: message, prefill: prefill)
    setComposerMessage(updated, moveCursorToEnd: true)
    updateCommandDeckCompletion(message)
    requestComposerFocus()
    Platform.services.playHaptic(.selection)
  }

  func clearCommandDeckState() {
    commandDeckActive = false
    commandDeckQuery = ""
    commandDeckIndex = 0
  }

  func removeTrailingCommandDeckToken() {
    guard let updated = ComposerTextEditing.removingTrailingCommandDeckToken(in: message) else { return }
    setComposerMessage(updated, moveCursorToEnd: true)
  }

  func replaceTrailingCommandDeckToken(with replacement: String, appendSpace: Bool = true) {
    let updated = ComposerTextEditing.replacingTrailingCommandDeckToken(
      in: message,
      replacement: replacement,
      appendSpace: appendSpace
    )
    setComposerMessage(updated, moveCursorToEnd: true)
  }

  func acceptCommandDeckItem(_ item: ComposerCommandDeckItem) {
    switch item.kind {
      case .openFilePicker:
        clearCommandDeckState()
        removeTrailingCommandDeckToken()
        openFilePicker()

      case .openSkillsPanel:
        clearCommandDeckState()
        removeTrailingCommandDeckToken()
        if hasSkillsPanel {
          serverState.listSkills(sessionId: sessionId)
        }
        onOpenSkills?()

      case .toggleShellMode:
        clearCommandDeckState()
        removeTrailingCommandDeckToken()
        withAnimation(Motion.gentle) {
          manualShellMode.toggle()
          if manualShellMode { manualReviewMode = false }
        }

      case let .insertText(text):
        clearCommandDeckState()
        replaceTrailingCommandDeckToken(with: text, appendSpace: false)

      case .refreshMcp:
        clearCommandDeckState()
        removeTrailingCommandDeckToken()
        serverState.refreshMcpServers(sessionId: sessionId)

      case let .attachFile(file):
        clearCommandDeckState()
        attachMentionFromPicker(file)

      case let .attachSkill(skill):
        selectedSkills.insert(skill.path)
        clearCommandDeckState()
        replaceTrailingCommandDeckToken(with: "$\(skill.name)")

      case let .insertMcpTool(server, tool):
        clearCommandDeckState()
        let snippet = "Use MCP tool \(server).\(tool.name)"
        replaceTrailingCommandDeckToken(with: snippet)

      case let .insertMcpResource(server, resource):
        clearCommandDeckState()
        let snippet = "Use MCP resource \(server):\(resource.uri)"
        replaceTrailingCommandDeckToken(with: snippet)
    }
    requestComposerFocus()
  }

  // MARK: - Keyboard Navigation

  enum ComposerCompletionCommand {
    case escape
    case upArrow
    case downArrow
    case accept
    case controlN
    case controlP
  }

  func handleComposerTextAreaKeyCommand(_ keyCommand: ComposerTextAreaKeyCommand) -> Bool {
    switch keyCommand {
      case .commandShiftT:
        withAnimation(Motion.gentle) {
          manualShellMode.toggle()
          if manualShellMode { manualReviewMode = false }
        }
        return true

      case .shiftReturn:
        // Let the native text view insert the newline so caret/selection stays correct.
        return false

      case .escape:
        return handleCompletionCommand(.escape)

      case .upArrow:
        return handleCompletionCommand(.upArrow)

      case .downArrow:
        return handleCompletionCommand(.downArrow)

      case .tab:
        return handleCompletionCommand(.accept)

      case .controlN:
        return handleCompletionCommand(.controlN)

      case .controlP:
        return handleCompletionCommand(.controlP)

      case .returnKey:
        if handleCompletionCommand(.accept) {
          return true
        }
        let hasContent = !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasContent || hasAttachments {
          sendMessage()
          return true
        }
        return false
    }
  }

  func handleCompletionCommand(_ command: ComposerCompletionCommand) -> Bool {
    if command == .escape {
      if shouldShowCommandDeck {
        clearCommandDeckState()
        removeTrailingCommandDeckToken()
        return true
      }
      if mentionActive {
        mentionActive = false
        return true
      }
      guard completionActive else { return false }
      completionActive = false
      return true
    }

    if shouldShowCommandDeck {
      return handleCommandDeckCommand(command)
    }

    if shouldShowMentionCompletion {
      return handleMentionCommand(command)
    }

    guard shouldShowCompletion else { return false }

    switch command {
      case .upArrow:
        completionIndex = max(0, completionIndex - 1)
        return true
      case .downArrow:
        completionIndex = min(filteredSkills.count - 1, completionIndex + 1)
        return true
      case .controlN:
        completionIndex = min(filteredSkills.count - 1, completionIndex + 1)
        return true
      case .controlP:
        completionIndex = max(0, completionIndex - 1)
        return true
      case .accept:
        acceptSkillCompletion(filteredSkills[completionIndex])
        return true
      case .escape:
        return false
    }
  }

  func handleCommandDeckCommand(_ command: ComposerCompletionCommand) -> Bool {
    let maxIndex = commandDeckItems.count - 1
    guard maxIndex >= 0 else { return false }

    switch command {
      case .upArrow:
        commandDeckIndex = max(0, commandDeckIndex - 1)
        return true
      case .downArrow:
        commandDeckIndex = min(maxIndex, commandDeckIndex + 1)
        return true
      case .controlN:
        commandDeckIndex = min(maxIndex, commandDeckIndex + 1)
        return true
      case .controlP:
        commandDeckIndex = max(0, commandDeckIndex - 1)
        return true
      case .accept:
        if commandDeckIndex < commandDeckItems.count {
          acceptCommandDeckItem(commandDeckItems[commandDeckIndex])
        }
        return true
      case .escape:
        return false
    }
  }

  func handleMentionCommand(_ command: ComposerCompletionCommand) -> Bool {
    let maxIndex = filteredFiles.count - 1
    guard maxIndex >= 0 else { return false }

    switch command {
      case .upArrow:
        mentionIndex = max(0, mentionIndex - 1)
        return true
      case .downArrow:
        mentionIndex = min(maxIndex, mentionIndex + 1)
        return true
      case .controlN:
        mentionIndex = min(maxIndex, mentionIndex + 1)
        return true
      case .controlP:
        mentionIndex = max(0, mentionIndex - 1)
        return true
      case .accept:
        if mentionIndex < filteredFiles.count {
          acceptMentionCompletion(filteredFiles[mentionIndex])
        }
        return true
      case .escape:
        return false
    }
  }
}
