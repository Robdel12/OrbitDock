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
    let presentation = pendingPresentation(for: model)
    let header = ApprovalCardConfiguration.headerConfig(for: model, mode: model.mode)
    let modeColor = pendingPanelModeColor(model)

    DirectSessionComposerPendingInlineZone(
      modeColor: modeColor,
      isExpanded: pendingState.isExpanded,
      contentHeight: presentation.clampedContentHeight,
      onMeasuredHeightChanged: { normalizedHeight in
        guard abs(normalizedHeight - pendingState.measuredContentHeight) > 0.5 else { return }
        pendingState.measuredContentHeight = normalizedHeight
      },
      header: {
        PendingPanelInlineHeader(
          title: presentation.title,
          statusText: presentation.statusText,
          promptCountText: presentation.promptCountText,
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
              if model.elicitationMode != nil {
                pendingElicitationInlineContent(model)
              } else {
                pendingQuestionInlineContent(model)
              }
            case .takeover:
              pendingTakeOverInlineContent(model)
            case .passiveBlocked:
              pendingPassiveBlockedInlineContent(model)
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

  func pendingPresentation(for model: ApprovalCardModel) -> DirectSessionComposerPendingPresentation {
    DirectSessionComposerPendingPlanner.presentation(
      for: model,
      showsDenyReason: pendingState.showsDenyReason,
      measuredHeight: pendingState.measuredContentHeight,
      maxHeight: pendingPanelContentMaxHeight()
    )
  }

  func pendingPanelModeColor(_ model: ApprovalCardModel) -> Color {
    switch model.mode {
      case .permission, .takeover: model.risk.tintColor
      case .question: Color.statusQuestion
      case .passiveBlocked: Color.feedbackCaution
      case .none: Color.textTertiary
    }
  }

  private func pendingPanelContentMaxHeight() -> CGFloat {
    isCompactLayout ? 220 : 260
  }

  // MARK: - Permission Inline Content (no action buttons)

  @ViewBuilder
  func pendingPermissionInlineContent(_ model: ApprovalCardModel) -> some View {
    if let permissionRequest = model.permissionRequest, model.approvalType == .permissions {
      pendingRequestPermissionsInlineContent(permissionRequest, model: model)
    } else {
      let presentation = pendingPresentation(for: model)
      let modeColor = pendingPanelModeColor(model)
      // ━━━ Command / preview display ━━━
      if presentation.showsCommandChain {
        let isSingleStep = presentation.commandChainSegments.count == 1

        VStack(alignment: .leading, spacing: isCompactLayout ? Spacing.xxs : Spacing.sm_) {
          if !isSingleStep, !isCompactLayout {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
              Text("Command Chain")
                .font(.system(size: TypeScale.micro, weight: .semibold))
                .foregroundStyle(Color.textTertiary)

              Text("\(presentation.commandChainSegments.count) steps")
                .font(.system(size: TypeScale.mini, weight: .medium))
                .foregroundStyle(Color.textQuaternary)
            }
          }

          ForEach(Array(presentation.commandChainSegments.enumerated()), id: \.offset) { index, segment in
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
        Text(presentation.previewText)
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

      // ━━━ Network approval context ━━━
      if let host = model.networkHost, !host.isEmpty {
        let proto = model.networkProtocol ?? "unknown"
        PendingInfoHintRow(
          iconName: "network",
          iconColor: Color.feedbackCaution,
          text: "Network: \(host) (\(proto))"
        )
      }

      // ━━━ Deny reason text field (cancel/send buttons in footer) ━━━
      if pendingState.showsDenyReason {
        PendingDenyReasonField(text: $pendingState.denyReason)
      }
    }
  }

  @ViewBuilder
  private func pendingRequestPermissionsInlineContent(
    _ request: ApprovalPermissionRequest,
    model: ApprovalCardModel
  ) -> some View {
    let modeColor = pendingPanelModeColor(model)

    VStack(alignment: .leading, spacing: Spacing.sm_) {
      if let reason = request.reason, !reason.isEmpty {
        Text(reason)
          .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.caption, weight: .medium))
          .foregroundStyle(Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if !request.groups.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.sm_) {
          ForEach(request.groups, id: \.self) { group in
            pendingPermissionGroupCard(group, tint: modeColor)
          }
        }
      } else {
        PendingInfoHintRow(
          iconName: "hand.raised.fill",
          iconColor: modeColor,
          text: "Review and grant the requested permissions to continue."
        )
      }

      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Grant Scope")
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(Color.textTertiary)

        Picker("Grant Scope", selection: $pendingState.permissionGrantScope) {
          ForEach(ServerPermissionGrantScope.allCases) { scope in
            Text(scope.title).tag(scope)
          }
        }
        .pickerStyle(.segmented)
      }

      if pendingState.showsDenyReason {
        PendingDenyReasonField(text: $pendingState.denyReason)
      }
    }
  }

  private func pendingPermissionGroupCard(
    _ group: ApprovalPermissionGroup,
    tint: Color
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: group.iconName)
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(tint)
        Text(group.title)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
      }

      VStack(alignment: .leading, spacing: 6) {
        ForEach(group.lines, id: \.self) { line in
          HStack(alignment: .top, spacing: Spacing.xs) {
            Circle()
              .fill(tint.opacity(OpacityTier.strong))
              .frame(width: 4, height: 4)
              .padding(.top, 6)

            Text(line)
              .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.caption, weight: .regular))
              .foregroundStyle(Color.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
    .padding(.horizontal, isCompactLayout ? Spacing.sm : Spacing.md_)
    .padding(.vertical, isCompactLayout ? Spacing.sm_ : Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundCode)
        .overlay(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(tint.opacity(OpacityTier.tint))
        )
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(tint.opacity(OpacityTier.light), lineWidth: 0.5)
    )
  }

  // MARK: - Question Inline Content (no action buttons)

  @ViewBuilder
  func pendingQuestionInlineContent(_ model: ApprovalCardModel) -> some View {
    let questionState = DirectSessionComposerPendingPlanner.questionContentState(
      prompts: model.questions,
      promptIndex: pendingState.promptIndex
    )

    if questionState.prompts.isEmpty {
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
        prompts: questionState.prompts,
        activeIndex: questionState.activeIndex,
        isCompactLayout: isCompactLayout,
        answeredState: questionState.prompts.map(pendingPromptIsAnswered),
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

  // MARK: - Passive Blocked Inline Content

  func pendingPassiveBlockedInlineContent(_ model: ApprovalCardModel) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      Text("This session requires approval. Respond in your terminal, or take over to approve here.")
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

      if let toolName = model.toolName, !toolName.isEmpty {
        PendingInfoHintRow(
          iconName: ToolCardStyle.icon(for: toolName),
          iconColor: Color.feedbackCaution,
          text: toolName
        )
      }
    }
  }

  // MARK: - MCP Elicitation Inline Content

  @ViewBuilder
  func pendingElicitationInlineContent(_ model: ApprovalCardModel) -> some View {
    let modeColor = pendingPanelModeColor(model)

    VStack(alignment: .leading, spacing: Spacing.sm) {
      if let serverName = model.mcpServerName, !serverName.isEmpty {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "server.rack")
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(modeColor)
          Text(serverName)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
        }
      }

      if let message = model.elicitationMessage, !message.isEmpty {
        Text(message)
          .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.caption, weight: .medium))
          .foregroundStyle(Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if model.elicitationMode == .url, let url = model.elicitationUrl, !url.isEmpty {
        PendingInfoHintRow(
          iconName: "safari",
          iconColor: modeColor,
          text: "Open in browser to complete authentication"
        )
      } else {
        // Form mode — fall through to standard question UI for now
        // Schema-driven form rendering can be added when codex-protocol exposes requested_schema
        pendingQuestionInlineContent(model)
      }
    }
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
      case .passiveBlocked:
        passiveBlockedFooterActions(model)
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
    let footerState = DirectSessionComposerPendingPlanner.permissionFooterState(
      denyActions: denyActions,
      approveActions: approveActions,
      showsDenyReason: pendingState.showsDenyReason,
      hasDenyReason: pendingState.hasDenyReason
    )
    let buttonSize: CGFloat = isCompactLayout ? 34 : 28

    DirectSessionComposerPendingPermissionFooter(
      state: footerState,
      alternateDenyActions: Array(denyActions.dropFirst()),
      alternateApproveActions: Array(approveActions.dropFirst()),
      buttonSize: buttonSize,
      modeColor: modeColor,
      isCompactLayout: isCompactLayout,
      onCancelDenyReason: {
        pendingState.cancelDenyReason()
        Platform.services.playHaptic(.selection)
      },
      onSubmitDenyReason: {
        if model.approvalType == .permissions {
          sendPendingPermissionResponse(model: model, granted: false)
        } else {
          let reason = pendingState.denyReason.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !reason.isEmpty else { return }
          sendPendingDecision(
            model: model, decision: "denied", message: reason, interrupt: nil
          )
          pendingState.cancelDenyReason()
        }
      },
      onPrimaryDeny: {
        handlePendingPermissionAction(
          model: model,
          action: footerState.primaryDenyAction
            ?? ApprovalCardConfiguration.MenuAction(title: "Deny", decision: "denied")
        )
      },
      onPrimaryApprove: {
        handlePendingPermissionAction(
          model: model,
          action: footerState.primaryApproveAction
            ?? ApprovalCardConfiguration.MenuAction(title: "Approve", decision: "approved")
        )
      },
      onOverflowAction: { action in
        handlePendingPermissionAction(model: model, action: action)
      }
    )
  }

  // MARK: Question Footer

  @ViewBuilder
  private func questionFooterActions(_ model: ApprovalCardModel) -> some View {
    let prompts = model.questions
    let buttonSize: CGFloat = isCompactLayout ? 34 : 28

    if prompts.isEmpty {
      // Simple single response — dismiss + submit
      let footerState = DirectSessionComposerPendingPlanner.questionFooterState(
        prompts: prompts,
        promptIndex: pendingState.promptIndex,
        answers: pendingState.answers,
        drafts: pendingState.drafts
      )

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
          fillColor: footerState.submitDisabled ? Color.surfaceHover : Color.statusQuestion.opacity(0.85),
          isDisabled: footerState.submitDisabled
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
      let footerState = DirectSessionComposerPendingPlanner.questionFooterState(
        prompts: prompts,
        promptIndex: pendingState.promptIndex,
        answers: pendingState.answers,
        drafts: pendingState.drafts
      )

      DirectSessionComposerPendingQuestionFooter(
        prompts: prompts,
        activeIndex: footerState.activeIndex,
        submitDisabled: footerState.submitDisabled,
        isCompactLayout: isCompactLayout,
        onDismiss: {
          sendPendingDecision(model: model, decision: "denied", message: "Dismissed", interrupt: nil)
        },
        onBack: {
          withAnimation(Motion.gentle) {
            pendingState.promptIndex = max(0, footerState.activeIndex - 1)
          }
          Platform.services.playHaptic(.selection)
        },
        onAdvance: {
          withAnimation(Motion.gentle) {
            pendingState.promptIndex = footerState.activeIndex + 1
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
    DirectSessionComposerPendingTakeoverFooter(
      title: ApprovalCardConfiguration.takeoverButtonTitle(for: model),
      onTakeover: {
        Platform.services.playHaptic(.success)
        Task { try? await serverState.takeoverSession(model.sessionId) }
      }
    )
  }

  // MARK: Passive Blocked Footer

  private func passiveBlockedFooterActions(_ model: ApprovalCardModel) -> some View {
    HStack(spacing: Spacing.sm_) {
      Spacer()
      Button {
        Platform.services.playHaptic(.success)
        Task { try? await serverState.takeoverSession(model.sessionId) }
      } label: {
        Text("Take Over")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
          .padding(.horizontal, Spacing.md_)
          .padding(.vertical, Spacing.sm_)
          .background(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
              .fill(Color.feedbackCaution.opacity(0.2))
          )
      }
      .buttonStyle(.plain)
    }
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
    DirectSessionComposerPendingPlanner.hapticForDecision(decision)
  }

  private func handlePendingPermissionAction(
    model: ApprovalCardModel,
    action: ApprovalCardConfiguration.MenuAction
  ) {
    if model.approvalType == .permissions {
      switch action.decision {
        case "deny_reason":
          pendingState.showsDenyReason = true
          Platform.services.playHaptic(.selection)
        case "approved", "approved_for_session", "approved_always":
          sendPendingPermissionResponse(model: model, granted: true)
        default:
          sendPendingPermissionResponse(model: model, granted: false)
      }
      return
    }

    if action.decision == "deny_reason" {
      pendingState.showsDenyReason = true
      Platform.services.playHaptic(.selection)
    } else {
      sendPendingDecision(
        model: model,
        decision: action.decision,
        message: nil,
        interrupt: nil
      )
    }
  }

  private func sendPendingPermissionResponse(
    model: ApprovalCardModel,
    granted: Bool
  ) {
    guard let requestId = model.approvalId else { return }
    Task {
      do {
        try await serverState.respondToPermissionRequest(
          sessionId: model.sessionId,
          requestId: requestId,
          scope: pendingState.permissionGrantScope,
          grantRequestedPermissions: granted
        )
        Platform.services.playHaptic(granted ? .success : .warning)
        if !granted {
          pendingState.cancelDenyReason()
        }
      } catch {
        Platform.services.playHaptic(.warning)
      }
    }
  }
}
