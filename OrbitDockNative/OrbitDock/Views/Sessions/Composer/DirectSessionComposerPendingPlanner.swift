import Foundation

struct DirectSessionComposerPendingPermissionFooterState: Equatable {
  let showsDenyReason: Bool
  let primaryDenyAction: ApprovalCardConfiguration.MenuAction?
  let primaryApproveAction: ApprovalCardConfiguration.MenuAction?
  let hasOverflowActions: Bool
  let denySubmitDisabled: Bool
}

struct DirectSessionComposerPendingQuestionFooterState: Equatable {
  let activeIndex: Int
  let submitDisabled: Bool
}

enum DirectSessionComposerPendingPlanner {
  static func title(for model: ApprovalCardModel) -> String {
    switch model.mode {
      case .permission:
        if model.approvalType == .permissions {
          "Permissions Request"
        } else {
          model.toolName ?? "Tool"
        }
      case .question:
        "Question"
      case .takeover:
        model.toolName ?? "Takeover"
      case .none:
        ""
    }
  }

  static func statusBadgeText(for model: ApprovalCardModel) -> String {
    switch model.mode {
      case .permission:
        model.approvalType == .permissions ? "PERMISSIONS" : "APPROVAL"
      case .question:
        "QUESTION"
      case .takeover:
        "TAKEOVER"
      case .none:
        ""
    }
  }

  static func fallbackContentHeight(
    for model: ApprovalCardModel,
    showsDenyReason: Bool
  ) -> CGFloat {
    switch model.mode {
      case .permission:
        if model.approvalType == .permissions {
          showsDenyReason ? 188 : 164
        } else {
          showsDenyReason ? 116 : 96
        }
      case .question:
        152
      case .takeover:
        72
      case .none:
        44
    }
  }

  static func clampedContentHeight(
    measuredHeight: CGFloat,
    maxHeight: CGFloat,
    fallbackHeight: CGFloat
  ) -> CGFloat {
    let resolvedHeight = measuredHeight > 0 ? measuredHeight : fallbackHeight
    return min(maxHeight, resolvedHeight)
  }

  static func toggledAnswers(
    existingAnswers: [String: [String]],
    questionId: String,
    optionLabel: String,
    allowsMultipleSelection: Bool
  ) -> [String: [String]] {
    var answers = existingAnswers
    var values = answers[questionId] ?? []

    if allowsMultipleSelection {
      if let index = values.firstIndex(of: optionLabel) {
        values.remove(at: index)
      } else {
        values.append(optionLabel)
      }
    } else {
      values = [optionLabel]
    }

    if values.isEmpty {
      answers.removeValue(forKey: questionId)
    } else {
      answers[questionId] = values
    }

    return answers
  }

  static func promptIsAnswered(
    prompt: ApprovalQuestionPrompt,
    answers: [String: [String]],
    drafts: [String: String]
  ) -> Bool {
    let hasSelectedOption = !(answers[prompt.id] ?? []).isEmpty
    let hasDraft = !(drafts[prompt.id] ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty
    return hasSelectedOption || hasDraft
  }

  static func allPromptsAnswered(
    prompts: [ApprovalQuestionPrompt],
    answers: [String: [String]],
    drafts: [String: String]
  ) -> Bool {
    prompts.allSatisfy { prompt in
      promptIsAnswered(prompt: prompt, answers: answers, drafts: drafts)
    }
  }

  static func collectedAnswers(
    prompts: [ApprovalQuestionPrompt],
    answers: [String: [String]],
    drafts: [String: String]
  ) -> [String: [String]] {
    var collected: [String: [String]] = [:]

    for prompt in prompts {
      var values = answers[prompt.id] ?? []
      let draft = (drafts[prompt.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if !draft.isEmpty, !values.contains(draft) {
        values.append(draft)
      }
      if !values.isEmpty {
        collected[prompt.id] = values
      }
    }

    return collected
  }

  static func primaryAnswer(
    prompts: [ApprovalQuestionPrompt],
    answers: [String: [String]]
  ) -> (questionId: String?, answer: String?) {
    let primaryQuestionId = prompts.first?.id

    if let primaryQuestionId, let value = answers[primaryQuestionId]?.first {
      return (primaryQuestionId, value)
    }

    for prompt in prompts {
      if let value = answers[prompt.id]?.first {
        return (primaryQuestionId, value)
      }
    }

    return (primaryQuestionId, answers.values.first?.first)
  }

  static func normalizedApprovalRequestId(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  static func permissionFooterState(
    denyActions: [ApprovalCardConfiguration.MenuAction],
    approveActions: [ApprovalCardConfiguration.MenuAction],
    showsDenyReason: Bool,
    hasDenyReason: Bool
  ) -> DirectSessionComposerPendingPermissionFooterState {
    DirectSessionComposerPendingPermissionFooterState(
      showsDenyReason: showsDenyReason,
      primaryDenyAction: denyActions.first,
      primaryApproveAction: approveActions.first,
      hasOverflowActions: denyActions.count > 1 || approveActions.count > 1,
      denySubmitDisabled: showsDenyReason && !hasDenyReason
    )
  }

  static func questionFooterState(
    prompts: [ApprovalQuestionPrompt],
    promptIndex: Int,
    answers: [String: [String]],
    drafts: [String: String]
  ) -> DirectSessionComposerPendingQuestionFooterState {
    let boundedIndex = min(max(promptIndex, 0), max(0, prompts.count - 1))
    let submitDisabled = if prompts.isEmpty {
      !(drafts["default"] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty
    } else if boundedIndex >= prompts.count - 1 {
      !allPromptsAnswered(prompts: prompts, answers: answers, drafts: drafts)
    } else {
      !promptIsAnswered(prompt: prompts[boundedIndex], answers: answers, drafts: drafts)
    }

    return DirectSessionComposerPendingQuestionFooterState(
      activeIndex: boundedIndex,
      submitDisabled: submitDisabled
    )
  }

  static func hapticForDecision(_ decision: String) -> AppHaptic {
    switch decision {
      case "approved", "approved_for_session", "approved_always":
        .success
      case "abort":
        .destructive
      default:
        .warning
    }
  }
}
