//
//  DirectSessionComposer+PendingPanel.swift
//  OrbitDock
//
//  Pending action panel — renders inline inside the composer surface.
//  Content sits above the text input; action buttons live in the footer.
//

import os
import SwiftUI

private let approvalLog = Logger(subsystem: "com.orbitdock", category: "approval-panel")

struct PendingPanelContentHeightPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

extension DirectSessionComposer {
  // MARK: - Inline Pending Zone (inside composer surface)

  @ViewBuilder
  func pendingInlineZone(_ model: ApprovalCardModel) -> some View {
    let header = ApprovalCardConfiguration.headerConfig(for: model, mode: model.mode)
    let modeColor = pendingPanelModeColor(model)

    DirectSessionComposerPendingInlineZone(
      modeColor: modeColor,
      isExpanded: pendingState.isExpanded,
      contentHeight: pendingPanelClampedContentHeight(for: model),
      onMeasuredHeightChanged: { normalizedHeight in
        guard abs(normalizedHeight - pendingState.measuredContentHeight) > 0.5 else { return }
        pendingState.measuredContentHeight = normalizedHeight
      },
      header: {
        PendingPanelInlineHeader(
          title: pendingPanelTitle(model),
          statusText: pendingPanelStatusBadgeText(model),
          promptCountText: model.mode == .question && model.questions.count > 1 ? "\(model.questions.count) prompts" : nil,
          header: header,
          modeColor: modeColor,
          isExpanded: pendingState.isExpanded,
          isHovering: pendingState.isHovering,
          onToggle: {
            withAnimation(Motion.standard) {
              pendingState.isExpanded.toggle()
            }
            Platform.services.playHaptic(.expansion)
          },
          onHoverChanged: { hovering in
            pendingState.isHovering = hovering
            #if os(macOS)
              if hovering {
                NSCursor.pointingHand.push()
              } else {
                NSCursor.pop()
              }
            #endif
          }
        )
      },
      content: {
        VStack(alignment: .leading, spacing: isCompactLayout ? Spacing.sm_ : Spacing.sm) {
          switch model.mode {
            case .permission:
              pendingPermissionInlineContent(model)
            case .question:
              pendingQuestionInlineContent(model)
            case .takeover:
              pendingTakeOverInlineContent(model)
            case .none:
              EmptyView()
          }
        }
        .padding(.horizontal, isCompactLayout ? Spacing.sm : Spacing.md_)
        .padding(.top, isCompactLayout ? Spacing.xs : Spacing.sm_)
        .padding(.bottom, isCompactLayout ? Spacing.sm_ : Spacing.sm_)
      }
    )
  }

  // MARK: - Helpers

  func pendingPanelModeColor(_ model: ApprovalCardModel) -> Color {
    switch model.mode {
      case .permission, .takeover: model.risk.tintColor
      case .question: Color.statusQuestion
      case .none: Color.textTertiary
    }
  }

  func pendingPanelTitle(_ model: ApprovalCardModel) -> String {
    DirectSessionComposerPendingPlanner.title(for: model)
  }

  private func pendingPanelStatusBadgeText(_ model: ApprovalCardModel) -> String {
    DirectSessionComposerPendingPlanner.statusBadgeText(for: model)
  }

  private func pendingPanelContentMaxHeight() -> CGFloat {
    isCompactLayout ? 220 : 260
  }

  private func pendingPanelFallbackHeight(for model: ApprovalCardModel) -> CGFloat {
    DirectSessionComposerPendingPlanner.fallbackContentHeight(
      for: model,
      showsDenyReason: pendingState.showsDenyReason
    )
  }

  private func pendingPanelClampedContentHeight(for model: ApprovalCardModel) -> CGFloat {
    DirectSessionComposerPendingPlanner.clampedContentHeight(
      measuredHeight: pendingState.measuredContentHeight,
      maxHeight: pendingPanelContentMaxHeight(),
      fallbackHeight: pendingPanelFallbackHeight(for: model)
    )
  }

  // MARK: - Permission Inline Content (no action buttons)

  @ViewBuilder
  func pendingPermissionInlineContent(_ model: ApprovalCardModel) -> some View {
    let previewText = model.command ?? model.filePath ?? "Review required before the session can continue."
    let modeColor = pendingPanelModeColor(model)
    let commandChainSegments: [ApprovalShellSegment] = {
      guard model.previewType == .shellCommand else { return [] }
      if !model.shellSegments.isEmpty { return model.shellSegments }
      if let command = model.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
        return [ApprovalShellSegment(command: command, leadingOperator: nil)]
      }
      return []
    }()
    // ━━━ Command / preview display ━━━
    if !commandChainSegments.isEmpty {
      let isSingleStep = commandChainSegments.count == 1

      VStack(alignment: .leading, spacing: isCompactLayout ? Spacing.xxs : Spacing.sm_) {
        if !isSingleStep, !isCompactLayout {
          HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text("Command Chain")
              .font(.system(size: TypeScale.micro, weight: .semibold))
              .foregroundStyle(Color.textTertiary)

            Text("\(commandChainSegments.count) steps")
              .font(.system(size: TypeScale.mini, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
          }
        }

        ForEach(Array(commandChainSegments.enumerated()), id: \.offset) { index, segment in
          if isSingleStep {
            PendingCommandCodeBlock(
              command: segment.command,
              modeColor: modeColor,
              isCompactLayout: isCompactLayout
            )
          } else {
            PendingCommandChainRow(
              index: index + 1,
              segment: segment,
              modeColor: modeColor,
              isCompactLayout: isCompactLayout
            )
          }
        }
      }
    } else {
      Text(previewText)
        .font(.system(
          size: isCompactLayout ? TypeScale.micro : TypeScale.caption,
          weight: .regular
        ))
        .foregroundStyle(Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.leading)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, isCompactLayout ? Spacing.sm : Spacing.md_)
        .padding(.vertical, isCompactLayout ? Spacing.xs : Spacing.sm_)
        .background(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(Color.backgroundCode)
            .overlay(
              RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(modeColor.opacity(OpacityTier.tint))
            )
        )
        .overlay(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(modeColor.opacity(OpacityTier.light), lineWidth: 0.5)
        )
    }

    // ━━━ Risk findings ━━━
    if !model.riskFindings.isEmpty {
      PendingRiskFindingsSection(
        findings: model.riskFindings,
        tint: model.risk.tintColor,
        highlightsBackground: model.risk == .high
      )
    }

    // ━━━ Decision scope hint ━━━
    if let scope = model.decisionScope, !scope.isEmpty {
      PendingInfoHintRow(
        iconName: "info.circle",
        iconColor: Color.textQuaternary,
        text: scope
      )
    }

    // ━━━ Amendment detail (what "Always Allow" would permit) ━━━
    if model.hasAmendment, let detail = model.amendmentDetail, !detail.isEmpty {
      PendingInfoHintRow(
        iconName: "shield.checkered",
        iconColor: Color.feedbackCaution,
        text: detail
      )
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.sm_)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(Color.feedbackCaution.opacity(OpacityTier.tint))
      )
    }

    // ━━━ Deny reason text field (cancel/send buttons in footer) ━━━
    if pendingState.showsDenyReason {
      PendingDenyReasonField(text: $pendingState.denyReason)
    }
  }

  // MARK: - Question Inline Content (no action buttons)

  @ViewBuilder
  func pendingQuestionInlineContent(_ model: ApprovalCardModel) -> some View {
    let prompts = model.questions
    if prompts.isEmpty {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        Text("Provide your response below, then submit.")
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(Color.textSecondary)

        pendingThemedTextField(
          "Your response",
          text: Binding(
            get: { pendingState.drafts["default"] ?? "" },
            set: { pendingState.drafts["default"] = $0 }
          )
        )
      }
    } else {
      DirectSessionComposerPendingQuestionContent(
        prompts: prompts,
        activeIndex: pendingState.promptIndex,
        isCompactLayout: isCompactLayout,
        answeredState: prompts.map(pendingPromptIsAnswered),
        answers: pendingState.answers,
        drafts: pendingState.drafts,
        onSelectPrompt: { index in
          withAnimation(Motion.gentle) {
            pendingState.promptIndex = index
          }
        },
        onToggleOption: { questionId, optionLabel, allowsMultipleSelection in
          pendingToggleAnswer(
            questionId: questionId,
            optionLabel: optionLabel,
            allowsMultipleSelection: allowsMultipleSelection
          )
        },
        onAdvanceAfterSingleSelection: {
          withAnimation(Motion.gentle) {
            pendingState.promptIndex += 1
          }
        },
        onDraftChanged: { questionId, value in
          pendingState.drafts[questionId] = value
        }
      )
    }
  }

  /// Themed text field matching the dark Cosmic Harbor aesthetic.
  func pendingThemedTextField(_ placeholder: String, text: Binding<String>) -> some View {
    TextField(placeholder, text: text)
      .textFieldStyle(.plain)
      .font(.system(size: TypeScale.caption))
      .foregroundStyle(Color.textPrimary)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.sm)
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(Color.backgroundCode)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .strokeBorder(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
      )
  }

  // MARK: - Takeover Inline Content

  func pendingTakeOverInlineContent(_ model: ApprovalCardModel) -> some View {
    Text("This session requires manual takeover before continuing.")
      .font(.system(size: TypeScale.caption, weight: .medium))
      .foregroundStyle(Color.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: - Footer Actions (rendered in composer footer right side)

  @ViewBuilder
  func pendingFooterActions(_ model: ApprovalCardModel) -> some View {
    let modeColor = pendingPanelModeColor(model)

    switch model.mode {
      case .permission:
        permissionFooterActions(model, modeColor: modeColor)
      case .question:
        questionFooterActions(model)
      case .takeover:
        takeoverFooterActions(model)
      case .none:
        HStack(spacing: Spacing.sm_) {
          footerFollowControls
          composerSendButton
        }
    }
  }

  // MARK: Permission Footer

  @ViewBuilder
  private func permissionFooterActions(
    _ model: ApprovalCardModel,
    modeColor: Color
  ) -> some View {
    let approveActions = ApprovalCardConfiguration.approveMenuActions(for: model)
    let denyActions = ApprovalCardConfiguration.denyMenuActions(for: model)
    let denyPrimary = denyActions.first
    let approvePrimary = approveActions.first
    let buttonSize: CGFloat = isCompactLayout ? 34 : 28

    HStack(spacing: Spacing.sm_) {
      if pendingState.showsDenyReason {
        // Cancel deny reason
        Button {
          pendingState.cancelDenyReason()
          Platform.services.playHaptic(.selection)
        } label: {
          Text("Cancel")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.textSecondary)
        }
        .buttonStyle(.plain)

        // Send denial
        let denyEmpty = !pendingState.hasDenyReason

        DirectSessionComposerPendingFooterIconButton(
          systemName: "xmark",
          iconSize: isCompactLayout ? TypeScale.subhead : TypeScale.caption,
          dimension: buttonSize,
          fillColor: denyEmpty ? Color.surfaceHover : Color.feedbackNegative.opacity(0.85),
          isDisabled: denyEmpty
        ) {
          let reason = pendingState.denyReason.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !reason.isEmpty else { return }
          sendPendingDecision(
            model: model, decision: "denied", message: reason, interrupt: nil
          )
          pendingState.cancelDenyReason()
        }
      } else {
        // Deny
        Button {
          if let denyPrimary {
            if denyPrimary.decision == "deny_reason" {
              pendingState.showsDenyReason = true
              Platform.services.playHaptic(.selection)
            } else {
              sendPendingDecision(
                model: model, decision: denyPrimary.decision, message: nil, interrupt: nil
              )
            }
          } else {
            sendPendingDecision(
              model: model, decision: "denied", message: nil, interrupt: nil
            )
          }
        } label: {
          Text(denyPrimary?.title ?? "Deny")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.feedbackNegative)
        }
        .buttonStyle(.plain)

        // Approve (replaces send button position)
        DirectSessionComposerPendingFooterIconButton(
          systemName: "checkmark",
          iconSize: isCompactLayout ? TypeScale.subhead : TypeScale.caption,
          dimension: buttonSize,
          fillColor: modeColor.opacity(0.85),
          isDisabled: false
        ) {
          if let approvePrimary {
            sendPendingDecision(
              model: model, decision: approvePrimary.decision, message: nil, interrupt: nil
            )
          } else {
            sendPendingDecision(
              model: model, decision: "approved", message: nil, interrupt: nil
            )
          }
        }

        // Overflow for alternate actions
        if denyActions.count > 1 || approveActions.count > 1 {
          Menu {
            if denyActions.count > 1 {
              Section("Deny") {
                ForEach(
                  Array(denyActions.dropFirst().enumerated()), id: \.offset
                ) { _, action in
                  Button(role: action.isDestructive ? .destructive : nil) {
                    if action.decision == "deny_reason" {
                      pendingState.showsDenyReason = true
                      Platform.services.playHaptic(.selection)
                    } else {
                      sendPendingDecision(
                        model: model, decision: action.decision,
                        message: nil, interrupt: nil
                      )
                    }
                  } label: {
                    Label(action.title, systemImage: action.iconName ?? "xmark")
                  }
                }
              }
            }
            if approveActions.count > 1 {
              Section("Approve") {
                ForEach(
                  Array(approveActions.dropFirst().enumerated()), id: \.offset
                ) { _, action in
                  Button {
                    sendPendingDecision(
                      model: model, decision: action.decision,
                      message: nil, interrupt: nil
                    )
                  } label: {
                    Label(action.title, systemImage: action.iconName ?? "checkmark")
                  }
                }
              }
            }
          } label: {
            Image(systemName: "ellipsis")
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(Color.textTertiary)
              .frame(
                width: isCompactLayout ? 28 : 22,
                height: isCompactLayout ? 28 : 22
              )
              .background(Circle().fill(Color.surfaceHover))
          }
          .menuStyle(.borderlessButton)
        }
      }
    }
  }

  // MARK: Question Footer

  @ViewBuilder
  private func questionFooterActions(_ model: ApprovalCardModel) -> some View {
    let prompts = model.questions
    let buttonSize: CGFloat = isCompactLayout ? 34 : 28

    if prompts.isEmpty {
      // Simple single response — dismiss + submit
      let submitDisabled = (pendingState.drafts["default"] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

      HStack(spacing: Spacing.sm_) {
        Button {
          sendPendingDecision(model: model, decision: "denied", message: "Dismissed", interrupt: nil)
        } label: {
          Text("Dismiss")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.textSecondary)
        }
        .buttonStyle(.plain)

        DirectSessionComposerPendingFooterIconButton(
          systemName: "arrow.up",
          iconSize: isCompactLayout ? TypeScale.subhead : TypeScale.caption,
          dimension: buttonSize,
          fillColor: submitDisabled ? Color.surfaceHover : Color.statusQuestion.opacity(0.85),
          isDisabled: submitDisabled
        ) {
          let answer = (pendingState.drafts["default"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
          guard let requestId = model.approvalId, !answer.isEmpty else { return }
          Task {
            try? await serverState.answerQuestion(
              sessionId: model.sessionId,
              requestId: requestId,
              answer: answer
            )
          }
        }
      }
    } else {
      let boundedIndex = min(
        max(pendingState.promptIndex, 0), max(0, prompts.count - 1)
      )
      let prompt = prompts[boundedIndex]
      let isDisabled = boundedIndex >= prompts.count - 1
        ? !pendingAllPromptsAnswered(prompts)
        : !pendingPromptIsAnswered(prompt)

      DirectSessionComposerPendingQuestionFooter(
        prompts: prompts,
        activeIndex: boundedIndex,
        submitDisabled: isDisabled,
        isCompactLayout: isCompactLayout,
        onDismiss: {
          sendPendingDecision(model: model, decision: "denied", message: "Dismissed", interrupt: nil)
        },
        onBack: {
          withAnimation(Motion.gentle) {
            pendingState.promptIndex = max(0, boundedIndex - 1)
          }
          Platform.services.playHaptic(.selection)
        },
        onAdvance: {
          withAnimation(Motion.gentle) {
            pendingState.promptIndex = boundedIndex + 1
          }
          Platform.services.playHaptic(.selection)
        },
        onSubmit: {
          sendPendingQuestionAnswers(model: model, prompts: prompts)
        }
      )
    }
  }

  // MARK: Takeover Footer

  private func takeoverFooterActions(_ model: ApprovalCardModel) -> some View {
    Button {
      Platform.services.playHaptic(.success)
      Task { try? await serverState.takeoverSession(model.sessionId) }
    } label: {
      Text(ApprovalCardConfiguration.takeoverButtonTitle(for: model))
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm_)
        .background(
          Capsule().fill(Color.accent.opacity(0.85))
        )
    }
    .buttonStyle(.plain)
  }

  // MARK: - State Management Helpers

  func resetPendingPanelStateForRequest() {
    pendingState.resetForNewRequest()
  }

  func normalizedApprovalRequestId(_ value: String?) -> String? {
    DirectSessionComposerPendingPlanner.normalizedApprovalRequestId(value)
  }

  func pendingToggleAnswer(
    questionId: String,
    optionLabel: String,
    allowsMultipleSelection: Bool
  ) {
    pendingState.answers = DirectSessionComposerPendingPlanner.toggledAnswers(
      existingAnswers: pendingState.answers,
      questionId: questionId,
      optionLabel: optionLabel,
      allowsMultipleSelection: allowsMultipleSelection
    )
    Platform.services.playHaptic(.selection)
  }

  func pendingPromptIsAnswered(_ prompt: ApprovalQuestionPrompt) -> Bool {
    DirectSessionComposerPendingPlanner.promptIsAnswered(
      prompt: prompt,
      answers: pendingState.answers,
      drafts: pendingState.drafts
    )
  }

  func pendingAllPromptsAnswered(_ prompts: [ApprovalQuestionPrompt]) -> Bool {
    DirectSessionComposerPendingPlanner.allPromptsAnswered(
      prompts: prompts,
      answers: pendingState.answers,
      drafts: pendingState.drafts
    )
  }

  func pendingCollectedAnswers(
    prompts: [ApprovalQuestionPrompt]
  ) -> [String: [String]] {
    DirectSessionComposerPendingPlanner.collectedAnswers(
      prompts: prompts,
      answers: pendingState.answers,
      drafts: pendingState.drafts
    )
  }

  func sendPendingQuestionAnswers(
    model: ApprovalCardModel,
    prompts: [ApprovalQuestionPrompt]
  ) {
    guard let requestId = model.approvalId else { return }
    let answers = pendingCollectedAnswers(prompts: prompts)
    guard !answers.isEmpty else { return }

    let primarySelection = DirectSessionComposerPendingPlanner.primaryAnswer(
      prompts: prompts,
      answers: answers
    )
    let primaryQuestionId = primarySelection.questionId
    let primaryAnswer = primarySelection.answer
    guard let primaryAnswer, !primaryAnswer.isEmpty else { return }

    Task {
      do {
        try await serverState.answerQuestion(
          sessionId: model.sessionId,
          requestId: requestId,
          answer: primaryAnswer,
          questionId: primaryQuestionId,
          answers: answers
        )
        Platform.services.playHaptic(.success)
      } catch {
        Platform.services.playHaptic(.warning)
      }
    }
  }

  func sendPendingDecision(
    model: ApprovalCardModel,
    decision: String,
    message: String?,
    interrupt: Bool?
  ) {
    guard let requestId = model.approvalId else { return }
    Task {
      do {
        try await serverState.approveTool(
          sessionId: model.sessionId,
          requestId: requestId,
          decision: decision,
          message: message,
          interrupt: interrupt
        )
        Platform.services.playHaptic(hapticForPendingDecision(decision))
      } catch {
        Platform.services.playHaptic(.warning)
        approvalLog.warning("[approval] decision returned stale for \(requestId)")
      }
    }
  }

  private func hapticForPendingDecision(_ decision: String) -> AppHaptic {
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
