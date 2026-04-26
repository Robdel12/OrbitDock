import SwiftUI

extension ControlDeckScreen {
  func handleTextChange(_ text: String) {
    let shouldLoadSkills = composer.handleTextChange(
      text,
      availableSkills: interaction.skills,
      allowsAutocomplete: !isShellMode
    )
    if shouldLoadSkills {
      Task { await interaction.loadSkills() }
    }
  }

  func handleKeyCommand(_ command: ControlDeckTextAreaKeyCommand) -> Bool {
    switch composer.handleKeyCommand(command, suggestions: currentSuggestions, canSubmit: canSubmit) {
    case .ignored:
      return false
    case .handled:
      return true
    case .submit:
      submitDraft()
      return true
    case let .accept(suggestion):
      acceptSuggestion(suggestion)
      return true
    }
  }

  func handleFocusEvent(_ event: ControlDeckTextAreaFocusEvent) {
    onFocusStateChange?(composer.handleFocusEvent(event))
  }

  func handleModuleAction(_ module: ControlDeckStatusModule, _ value: String) {
    netLog(.info, cat: .store, "ControlDeck module action tapped", sid: sessionId, data: [
      "module": module.rawValue,
      "value": value,
    ])
    Task {
      switch module {
      case .model:
        await interaction.updateModel(value)
      case .effort:
        await interaction.updateEffort(value)
      case .autonomy:
        await interaction.updatePermissionMode(value)
      case .approvalMode:
        await interaction.updateApprovalPolicy(value)
      case .collaborationMode:
        await interaction.updateCollaborationMode(value)
      case .autoReview:
        await interaction.updateAutoReview(value)
      default:
        break
      }
    }
  }

  func handleApprovalReviewerAction(_ reviewer: ServerCodexApprovalsReviewer) {
    netLog(.info, cat: .store, "ControlDeck approval reviewer action tapped", sid: sessionId, data: [
      "reviewer": reviewer.rawValue
    ])
    Task {
      await interaction.updateApprovalsReviewer(reviewer)
    }
  }

  func handleSandboxPolicyAction(_ policy: ServerCodexSandboxPolicy) {
    netLog(.info, cat: .store, "ControlDeck sandbox policy action tapped", sid: sessionId, data: [
      "policy": policy.summaryText
    ])
    Task {
      await interaction.updateSandboxPolicy(policy)
    }
  }

  func acceptSuggestion(_ suggestion: ControlDeckCompletionSuggestion) {
    composer.acceptSuggestion(
      suggestion,
      availableSkills: interaction.skills,
      projectPath: interaction.projectPath,
      projectFileIndex: interaction.projectFileIndex
    )
  }

  func submitDraft() {
    guard composer.draft.hasContent, !composer.isSubmitting else { return }

    let submissionAction = ControlDeckSubmissionPlanner.action(
      for: currentMode,
      intent: submissionIntent,
      sessionShellAvailable: sessionShellAvailable
    )
    composer.isSubmitting = true
    let currentDraft = composer.draft

    Task {
      defer { composer.isSubmitting = false }

      do {
        var imageIds = composer.uploadedImageIds
        if submissionAction != .submitShellCommand {
          for image in currentDraft.attachments.images where imageIds[image.localId] == nil {
            let attachmentId = try await interaction.uploadImage(
              data: image.uploadData,
              mimeType: image.uploadMimeType,
              displayName: image.displayName,
              pixelWidth: image.pixelWidth,
              pixelHeight: image.pixelHeight
            )
            imageIds[image.localId] = attachmentId
          }
        }

        composer.uploadedImageIds = imageIds

        if submissionAction == .submitShellCommand {
          try await interaction.submitShellCommand(draft: currentDraft)
        } else if submissionAction == .steerTurn {
          try await interaction.steerTurn(draft: currentDraft, uploadedImageIds: imageIds)
        } else {
          try await interaction.submitTurn(draft: currentDraft, uploadedImageIds: imageIds)
        }

        interaction.lastError = nil
        composer.clearDraft(for: sessionId)
      } catch {
        let message = error.localizedDescription
        interaction.lastError = message
        await interaction.refresh()
        if interaction.currentSessionId == sessionId {
          interaction.lastError = message
        }
        netLog(.error, cat: .store, "ControlDeck submit failed", sid: sessionId, data: [
          "action": String(describing: submissionAction),
          "error": message,
        ])
      }
    }
  }

  func toggleShellMode() {
    guard sessionShellSupported else { return }

    let nextIntent: ControlDeckSubmissionIntent = isShellMode ? .message : .shell
    composer.draft.submissionIntentOverride = nextIntent
    composer.completionState.dismiss()
    composer.focusState.requestFocus()
  }

  func resumeSession() {
    guard !composer.isSubmitting else { return }
    netLog(.info, cat: .store, "ControlDeckScreen resume tapped", sid: sessionId, data: [
      "isSubmitting": composer.isSubmitting,
      "isResuming": interaction.isResuming,
      "presentationMode": interaction.presentation?.mode.debugLabel ?? "nil",
      "canResume": interaction.presentation?.canResume ?? false
    ])
    Task { await interaction.resumeSession() }
  }

  func handleAttachmentImport(_ result: Result<[URL], Error>) {
    if let error = composer.handleAttachmentImport(result, projectPath: interaction.projectPath) {
      interaction.lastError = error
    }
  }

  func toggleDictation() {
    Task {
      if let error = await composer.toggleDictation(localDictationEnabled: localDictationEnabled) {
        interaction.lastError = error
      }
    }
  }

  func handleTurnControlAction(_ action: String) {
    netLog(.info, cat: .store, "ControlDeck turn control action tapped", sid: sessionId, data: [
      "action": action
    ])
    Task {
      switch action {
      case "undo":
        await interaction.undoLastTurn()
      case "compact":
        await interaction.compactContext()
      default:
        if let count = rollbackTurnCount(for: action) {
          await interaction.rollbackTurns(count)
        }
      }
    }
  }

  private func rollbackTurnCount(for action: String) -> Int? {
    guard action.hasPrefix("rollback:") else { return nil }
    return Int(action.dropFirst("rollback:".count))
  }
}
