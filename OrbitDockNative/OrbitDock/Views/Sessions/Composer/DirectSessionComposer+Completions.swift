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
    let needsSkillLoad = inputState.updateSkillCompletion(
      for: text,
      availableSkillNames: Set(availableSkills.map(\.name))
    )
    if needsSkillLoad {
      Task { try? await viewModel.listSkills() }
    }
  }

  func acceptSkillCompletion(_ skill: ServerSkillMetadata) {
    if let updated = ComposerTextEditing.applySkillCompletion(in: message, skillName: skill.name) {
      setComposerMessage(updated, moveCursorToEnd: true)
    }
    inputState.skillCompletion.dismiss()
    requestComposerFocus()
  }

  // MARK: - @ Mention Completion

  func updateMentionCompletion(_ text: String) {
    let shouldLoadProjectFiles = inputState.updateMentionCompletion(
      for: text,
      attachedMentions: attachmentState.mentions
    )
    if shouldLoadProjectFiles {
      loadProjectFilesIfNeeded()
    }
  }

  func acceptMentionCompletion(_ file: ProjectFileIndex.ProjectFile) {
    if let updated = ComposerTextEditing.applyMentionCompletion(in: message, fileName: file.name) {
      setComposerMessage(updated, moveCursorToEnd: true)
    }
    inputState.mentionCompletion.dismiss()
    requestComposerFocus()

    addMentionAttachment(file)
    Platform.services.playHaptic(.selection)
  }

  func addMentionAttachment(_ file: ProjectFileIndex.ProjectFile) {
    let mention = DirectSessionComposerAttachmentPlanner.buildMention(
      file: file,
      projectPath: projectPath
    )
    guard !attachmentState.mentions.contains(where: { $0.id == mention.id }) else { return }
    withAnimation(Motion.gentle) {
      _ = attachmentState.appendMention(mention)
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
    let loadRequests = inputState.updateCommandDeckCompletion(
      for: text,
      hasSkillsPanel: hasSkillsPanel,
      availableSkillsAreLoaded: !availableSkills.isEmpty,
      hasMcpTools: !viewModel.mcpTools.isEmpty
    )
    if loadRequests.contains(.skills) {
      Task { try? await viewModel.listSkills() }
    }
    if loadRequests.contains(.mcpTools) {
      Task { try? await viewModel.listMcpTools() }
    }
    if loadRequests.contains(.projectFiles) {
      loadProjectFilesIfNeeded()
    }
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
    inputState.clearCommandDeck()
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
          Task { try? await viewModel.listSkills() }
        }
        activateCommandDeck(prefill: "skill")

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
        Task { try? await viewModel.refreshMcpServers() }

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

      case let .insertMcpResourceTemplate(server, resourceTemplate):
        clearCommandDeckState()
        let snippet = "Use MCP resource template \(server):\(resourceTemplate.uriTemplate)"
        replaceTrailingCommandDeckToken(with: snippet)
    }
    requestComposerFocus()
  }

  // MARK: - Keyboard Navigation

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
      if inputState.mentionCompletion.isActive {
        inputState.dismissMentionCompletion()
        return true
      }
      guard inputState.skillCompletion.isActive else { return false }
      inputState.dismissSkillCompletion()
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
        _ = inputState.skillCompletion.move(command, itemCount: filteredSkills.count)
        return true
      case .downArrow:
        _ = inputState.skillCompletion.move(command, itemCount: filteredSkills.count)
        return true
      case .controlN:
        _ = inputState.skillCompletion.move(command, itemCount: filteredSkills.count)
        return true
      case .controlP:
        _ = inputState.skillCompletion.move(command, itemCount: filteredSkills.count)
        return true
      case .accept:
        acceptSkillCompletion(filteredSkills[inputState.skillCompletion.index])
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
        _ = inputState.commandDeck.move(command, itemCount: commandDeckItems.count)
        return true
      case .downArrow:
        _ = inputState.commandDeck.move(command, itemCount: commandDeckItems.count)
        return true
      case .controlN:
        _ = inputState.commandDeck.move(command, itemCount: commandDeckItems.count)
        return true
      case .controlP:
        _ = inputState.commandDeck.move(command, itemCount: commandDeckItems.count)
        return true
      case .accept:
        if inputState.commandDeck.index < commandDeckItems.count {
          acceptCommandDeckItem(commandDeckItems[inputState.commandDeck.index])
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
        _ = inputState.mentionCompletion.move(command, itemCount: filteredFiles.count)
        return true
      case .downArrow:
        _ = inputState.mentionCompletion.move(command, itemCount: filteredFiles.count)
        return true
      case .controlN:
        _ = inputState.mentionCompletion.move(command, itemCount: filteredFiles.count)
        return true
      case .controlP:
        _ = inputState.mentionCompletion.move(command, itemCount: filteredFiles.count)
        return true
      case .accept:
        if inputState.mentionCompletion.index < filteredFiles.count {
          acceptMentionCompletion(filteredFiles[inputState.mentionCompletion.index])
        }
        return true
      case .escape:
        return false
    }
  }
}
