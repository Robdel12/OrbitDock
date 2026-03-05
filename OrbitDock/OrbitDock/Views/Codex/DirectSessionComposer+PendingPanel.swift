//
//  DirectSessionComposer+PendingPanel.swift
//  OrbitDock
//
//  Pending action panel views and helpers (permission, question, takeover).
//

import SwiftUI

extension DirectSessionComposer {
  // MARK: - Pending Action Panel

  @ViewBuilder
  func pendingActionPanel(_ model: ApprovalCardModel) -> some View {
    let header = ApprovalCardConfiguration.headerConfig(for: model, mode: model.mode)
    let modeColor = pendingPanelModeColor(model)

    VStack(spacing: 0) {
      // ━━━ Header with edge bar ━━━
      Button {
        withAnimation(Motion.standard) {
          pendingPanelExpanded.toggle()
        }
      } label: {
        HStack(spacing: 0) {
          RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
            .fill(modeColor)
            .frame(width: EdgeBar.width)
            .padding(.vertical, Spacing.xs)

          HStack(alignment: .center, spacing: Spacing.sm) {
            Image(systemName: header.iconName)
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(header.iconTint)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
              HStack(spacing: Spacing.sm) {
                Text(pendingPanelTitle(model))
                  .font(.system(size: TypeScale.body, weight: .semibold))
                  .foregroundStyle(Color.textPrimary)

                if model.mode == .question, model.questions.count > 1 {
                  Text("\(model.questions.count)")
                    .font(.system(size: TypeScale.micro, weight: .bold))
                    .foregroundStyle(modeColor)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, Spacing.xxs)
                    .background(
                      Capsule()
                        .fill(modeColor.opacity(OpacityTier.light))
                    )
                }
              }

              Text(pendingPanelSubtitle(model))
                .font(.system(size: TypeScale.micro, weight: .medium))
                .foregroundStyle(Color.textTertiary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
              .font(.system(size: TypeScale.micro, weight: .bold))
              .foregroundStyle(Color.textTertiary)
              .rotationEffect(.degrees(pendingPanelExpanded ? 90 : 0))
              .animation(Motion.snappy, value: pendingPanelExpanded)
          }
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, Spacing.sm)
        }
        .background(pendingPanelHovering ? Color.surfaceHover : Color.clear)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .onHover { hovering in
        pendingPanelHovering = hovering
        #if os(macOS)
          if hovering {
            NSCursor.pointingHand.push()
          } else {
            NSCursor.pop()
          }
        #endif
      }

      // ━━━ Expandable content ━━━
      if pendingPanelExpanded {
        Divider()
          .overlay(modeColor.opacity(OpacityTier.tint))

        VStack(alignment: .leading, spacing: Spacing.sm) {
          switch model.mode {
            case .permission:
              pendingPermissionContent(model)
            case .question:
              pendingQuestionContent(model)
            case .takeover:
              pendingTakeOverContent(model)
            case .none:
              EmptyView()
          }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.md)
        .transition(.opacity.animation(Motion.gentle.delay(0.05)))
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.backgroundTertiary.opacity(0.5))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .strokeBorder(modeColor.opacity(OpacityTier.subtle), lineWidth: 1)
    )
    .themeShadow(Shadow.glow(color: modeColor, intensity: 0.25))
  }

  func pendingPanelModeColor(_ model: ApprovalCardModel) -> Color {
    switch model.mode {
      case .permission, .takeover: model.risk.tintColor
      case .question: Color.statusQuestion
      case .none: Color.textTertiary
    }
  }

  func pendingPanelTitle(_ model: ApprovalCardModel) -> String {
    switch model.mode {
      case .permission:
        model.toolName ?? "Tool"
      case .question:
        "Question"
      case .takeover:
        model.toolName ?? "Takeover"
      case .none:
        ""
    }
  }

  func pendingPanelSubtitle(_ model: ApprovalCardModel) -> String {
    switch model.mode {
      case .permission:
        "Approval Required"
      case .question:
        model.questions.count > 1
          ? "\(model.questions.count) questions"
          : "Awaiting your response"
      case .takeover:
        "Takeover Required"
      case .none:
        ""
    }
  }

  @ViewBuilder
  func pendingPermissionContent(_ model: ApprovalCardModel) -> some View {
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
    let shouldClampChainHeight =
      commandChainSegments.count > 2 ||
      commandChainSegments.contains(where: { $0.command.contains("\n") || $0.command.count > 240 })
    let approveActions = ApprovalCardConfiguration.approveMenuActions(for: model)
    let denyActions = ApprovalCardConfiguration.denyMenuActions(for: model)
    let denyPrimary = denyActions.first
    let approvePrimary = approveActions.first

    // ━━━ Command / preview display ━━━
    if !commandChainSegments.isEmpty {
      let isSingleStep = commandChainSegments.count == 1

      VStack(alignment: .leading, spacing: Spacing.xs) {
        // Only show chain header for multi-step commands
        if !isSingleStep {
          HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text("Command Chain")
              .font(.system(size: TypeScale.micro, weight: .semibold))
              .foregroundStyle(Color.textTertiary)

            Text("\(commandChainSegments.count) steps")
              .font(.system(size: TypeScale.mini, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
          }
        }

        if shouldClampChainHeight {
          Text("Scroll to inspect every line before approving.")
            .font(.system(size: TypeScale.mini, weight: .regular))
            .foregroundStyle(Color.textQuaternary)
        }

        ScrollView(.vertical, showsIndicators: true) {
          LazyVStack(spacing: Spacing.xs) {
            ForEach(Array(commandChainSegments.enumerated()), id: \.offset) { index, segment in
              if isSingleStep {
                // Single step: just the code block, no step badge or operator label
                pendingCommandCodeBlock(segment: segment, modeColor: modeColor)
              } else {
                pendingCommandChainRow(index: index + 1, segment: segment, modeColor: modeColor)
              }
            }
          }
        }
        .frame(maxHeight: shouldClampChainHeight ? (isCompactLayout ? 240 : 320) : nil)
      }
    } else {
      ScrollView(.vertical, showsIndicators: true) {
        Text(previewText)
          .font(.system(size: TypeScale.caption, weight: .regular))
          .foregroundStyle(Color.textSecondary)
          .lineLimit(nil)
          .fixedSize(horizontal: false, vertical: true)
          .multilineTextAlignment(.leading)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.sm)
      }
      .frame(maxHeight: isCompactLayout ? 240 : 320)
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(Color.backgroundCode)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .strokeBorder(modeColor.opacity(OpacityTier.subtle), lineWidth: 1)
      )
    }

    // ━━━ Risk findings ━━━
    if !model.riskFindings.isEmpty {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        ForEach(Array(model.riskFindings.enumerated()), id: \.offset) { _, finding in
          HStack(alignment: .top, spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(model.risk.tintColor)
            Text(finding)
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.textSecondary)
              .lineLimit(nil)
              .fixedSize(horizontal: false, vertical: true)
              .multilineTextAlignment(.leading)
          }
        }
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(model.risk == .high ? Color.statusError.opacity(OpacityTier.tint) : Color.clear)
      )
    }

    // ━━━ Deny reason input ━━━
    if pendingPanelShowDenyReason {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        TextField("Deny reason", text: $pendingPanelDenyReason)
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

        HStack(spacing: Spacing.sm) {
          Button("Cancel") {
            pendingPanelShowDenyReason = false
            pendingPanelDenyReason = ""
          }
          .buttonStyle(GhostButtonStyle(color: .textSecondary))

          Spacer()

          Button("Send Denial") {
            let reason = pendingPanelDenyReason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty else { return }
            sendPendingDecision(model: model, decision: "denied", message: reason, interrupt: nil)
            pendingPanelShowDenyReason = false
            pendingPanelDenyReason = ""
          }
          .buttonStyle(CosmicButtonStyle(color: .statusError))
          .disabled(pendingPanelDenyReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .opacity(pendingPanelDenyReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1.0)
        }
      }
    }

    // ━━━ Action buttons ━━━
    HStack(spacing: Spacing.sm) {
      Button(denyPrimary?.title ?? "Deny") {
        if let denyPrimary {
          if denyPrimary.decision == "deny_reason" {
            pendingPanelShowDenyReason = true
          } else {
            sendPendingDecision(model: model, decision: denyPrimary.decision, message: nil, interrupt: nil)
          }
        } else {
          sendPendingDecision(model: model, decision: "denied", message: nil, interrupt: nil)
        }
      }
      .buttonStyle(GhostButtonStyle(color: .statusError, size: isCompactLayout ? .large : .regular))
      .frame(minWidth: isCompactLayout ? 80 : 100)

      Button {
        if let approvePrimary {
          sendPendingDecision(model: model, decision: approvePrimary.decision, message: nil, interrupt: nil)
        } else {
          sendPendingDecision(model: model, decision: "approved", message: nil, interrupt: nil)
        }
      } label: {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "checkmark.shield.fill")
            .font(.system(size: TypeScale.caption, weight: .semibold))
          Text(approvePrimary?.title ?? "Approve")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(CosmicButtonStyle(color: modeColor, size: isCompactLayout ? .large : .regular))

      Menu {
        if denyActions.count > 1 {
          Section("Deny") {
            ForEach(Array(denyActions.dropFirst().enumerated()), id: \.offset) { _, action in
              Button(role: action.isDestructive ? .destructive : nil) {
                if action.decision == "deny_reason" {
                  pendingPanelShowDenyReason = true
                } else {
                  sendPendingDecision(model: model, decision: action.decision, message: nil, interrupt: nil)
                }
              } label: {
                Label(action.title, systemImage: action.iconName ?? "xmark")
              }
            }
          }
        }
        if approveActions.count > 1 {
          Section("Approve") {
            ForEach(Array(approveActions.dropFirst().enumerated()), id: \.offset) { _, action in
              Button {
                sendPendingDecision(model: model, decision: action.decision, message: nil, interrupt: nil)
              } label: {
                Label(action.title, systemImage: action.iconName ?? "checkmark")
              }
            }
          }
        }
      } label: {
        Image(systemName: "ellipsis.circle")
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.textSecondary)
          .frame(width: 32, height: 32)
          .background(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
              .fill(Color.clear)
          )
          .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
              .strokeBorder(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
          )
      }
      .menuStyle(.borderlessButton)
    }
    .transition(.opacity.animation(Motion.gentle.delay(0.1)))
  }

  /// Standalone code block for single-step commands (no badge, no operator label).
  func pendingCommandCodeBlock(segment: ApprovalShellSegment, modeColor: Color) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      Text(verbatim: segment.command)
        .font(.system(size: TypeScale.caption, weight: .regular, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
        .lineSpacing(2)
        .lineLimit(nil)
        .fixedSize(horizontal: true, vertical: true)
        .multilineTextAlignment(.leading)
        .textSelection(.enabled)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundCode)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(modeColor.opacity(OpacityTier.subtle), lineWidth: 1)
    )
  }

  /// Multi-step command chain row with numbered badge and operator label.
  func pendingCommandChainRow(index: Int, segment: ApprovalShellSegment, modeColor: Color) -> some View {
    let operatorText = segment.leadingOperator?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    return VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: Spacing.xs) {
        Text("\(index)")
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(modeColor)
          .frame(width: 14, height: 14)
          .background(
            Circle()
              .fill(modeColor.opacity(OpacityTier.light))
          )

        if let operatorText, !operatorText.isEmpty, index > 1 {
          let operatorHint = ApprovalPermissionPreviewHelpers.operatorLabel(operatorText) ?? "then"
          Text("[\(operatorText)] \(operatorHint)")
            .font(.system(size: TypeScale.mini, weight: .medium))
            .foregroundStyle(Color.textTertiary)
        } else {
          Text("Run first")
            .font(.system(size: TypeScale.mini, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
        }

        Spacer(minLength: 0)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        Text(verbatim: segment.command)
          .font(.system(size: TypeScale.caption, weight: .regular, design: .monospaced))
          .foregroundStyle(Color.textSecondary)
          .lineSpacing(2)
          .lineLimit(nil)
          .fixedSize(horizontal: true, vertical: true)
          .multilineTextAlignment(.leading)
          .textSelection(.enabled)
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, Spacing.sm)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .fill(Color.backgroundCode)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .strokeBorder(modeColor.opacity(OpacityTier.subtle), lineWidth: 1)
      )
    }
  }

  @ViewBuilder
  func pendingQuestionContent(_ model: ApprovalCardModel) -> some View {
    let prompts = model.questions
    if prompts.isEmpty {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        Text("Provide your response below, then submit.")
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(Color.textSecondary)

        pendingThemedTextField(
          "Your response",
          text: Binding(
            get: { pendingPanelDrafts["default"] ?? "" },
            set: { pendingPanelDrafts["default"] = $0 }
          )
        )

        Button("Submit Response") {
          let answer = (pendingPanelDrafts["default"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
          guard let requestId = model.approvalId, !answer.isEmpty else { return }
          serverState.answerQuestion(
            sessionId: model.sessionId,
            requestId: requestId,
            answer: answer,
            questionId: nil,
            answers: nil
          )
        }
        .buttonStyle(CosmicButtonStyle(color: .statusQuestion))
        .disabled(
          (pendingPanelDrafts["default"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        .opacity(
          (pendingPanelDrafts["default"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1.0
        )
      }
    } else {
      let boundedIndex = min(max(pendingPanelPromptIndex, 0), max(0, prompts.count - 1))
      let prompt = prompts[boundedIndex]

      VStack(alignment: .leading, spacing: Spacing.sm) {
        // ━━━ Progress header (only for multi-question) ━━━
        if prompts.count > 1 {
          HStack(alignment: .center, spacing: Spacing.sm) {
            Text("Question \(boundedIndex + 1) of \(prompts.count)")
              .font(.system(size: TypeScale.micro, weight: .semibold))
              .foregroundStyle(Color.textTertiary)

            Spacer(minLength: 0)

            // Progress dots
            HStack(spacing: Spacing.xs) {
              ForEach(0 ..< prompts.count, id: \.self) { i in
                let dotColor: Color = pendingPromptIsAnswered(prompts[i])
                  ? .statusQuestion
                  : i == boundedIndex ? Color.statusQuestion.opacity(0.4) : Color.textQuaternary.opacity(0.3)
                Circle()
                  .fill(dotColor)
                  .frame(width: 6, height: 6)
              }
            }
          }

          pendingQuestionMap(prompts: prompts, activeIndex: boundedIndex)
        }

        pendingPromptCard(prompt: prompt, index: boundedIndex, totalCount: prompts.count)

        // ━━━ Action buttons ━━━
        let isLastQuestion = boundedIndex >= prompts.count - 1
        let isDisabled = isLastQuestion
          ? !pendingAllPromptsAnswered(prompts)
          : !pendingPromptIsAnswered(prompt)

        HStack(spacing: Spacing.sm) {
          if prompts.count > 1 {
            Button("Back") {
              withAnimation(Motion.gentle) {
                pendingPanelPromptIndex = max(0, boundedIndex - 1)
              }
            }
            .buttonStyle(GhostButtonStyle(color: .textSecondary))
            .disabled(boundedIndex == 0)
            .opacity(boundedIndex == 0 ? 0.4 : 1.0)
          }

          Button {
            if !isLastQuestion {
              withAnimation(Motion.gentle) {
                pendingPanelPromptIndex = boundedIndex + 1
              }
            } else {
              sendPendingQuestionAnswers(model: model, prompts: prompts)
            }
          } label: {
            HStack(spacing: Spacing.xs) {
              Text(isLastQuestion ? "Submit" : "Next")
              if !isLastQuestion {
                Image(systemName: "arrow.right")
                  .font(.system(size: TypeScale.micro, weight: .bold))
              }
            }
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(CosmicButtonStyle(color: .statusQuestion))
          .disabled(isDisabled)
          .opacity(isDisabled ? 0.5 : 1.0)
        }
        .transition(.opacity.animation(Motion.gentle.delay(0.1)))
      }
    }
  }

  func pendingQuestionMap(prompts: [ApprovalQuestionPrompt], activeIndex: Int) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.xs) {
        ForEach(Array(prompts.enumerated()), id: \.offset) { index, prompt in
          let answered = pendingPromptIsAnswered(prompt)
          let header = prompt.header?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Q\(index + 1)"
          let isActive = index == activeIndex

          Button {
            withAnimation(Motion.gentle) {
              pendingPanelPromptIndex = index
            }
          } label: {
            HStack(spacing: Spacing.xs) {
              if answered {
                Image(systemName: "checkmark")
                  .font(.system(size: TypeScale.mini, weight: .bold))
              }
              Text(header)
                .font(.system(size: TypeScale.micro, weight: .semibold))
                .lineLimit(1)
            }
            .foregroundStyle(isActive ? Color.textPrimary : answered ? Color.statusQuestion : Color.textSecondary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .cosmicBadge(
              color: isActive ? .statusQuestion : answered ? .statusQuestion : .textQuaternary,
              shape: .roundedRect,
              backgroundOpacity: isActive ? OpacityTier.medium : answered ? OpacityTier.subtle : OpacityTier.tint
            )
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  func pendingPromptCard(prompt: ApprovalQuestionPrompt, index: Int, totalCount: Int) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      // ━━━ Question text ━━━
      Text(prompt.question)
        .font(.system(size: TypeScale.body, weight: .semibold))
        .foregroundStyle(Color.textPrimary)
        .lineSpacing(2)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.leading)

      // ━━━ Options ━━━
      if !prompt.options.isEmpty {
        Text(pendingPromptInstructionText(prompt))
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textTertiary)

        VStack(spacing: Spacing.xs) {
          ForEach(Array(prompt.options.enumerated()), id: \.offset) { _, option in
            let isSelected = (pendingPanelAnswers[prompt.id] ?? []).contains(option.label)
            Button {
              pendingToggleAnswer(
                questionId: prompt.id,
                optionLabel: option.label,
                allowsMultipleSelection: prompt.allowsMultipleSelection
              )
              if !prompt.allowsMultipleSelection, !prompt.allowsOther, index < totalCount - 1 {
                withAnimation(Motion.gentle) {
                  pendingPanelPromptIndex = index + 1
                }
              }
            } label: {
              HStack(spacing: Spacing.sm) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                  .font(.system(size: TypeScale.caption, weight: .medium))
                  .foregroundStyle(isSelected ? Color.statusQuestion : Color.textQuaternary)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                  Text(option.label)
                    .font(.system(size: TypeScale.caption, weight: .medium))
                    .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                  if let description = option.description, !description.isEmpty {
                    Text(description)
                      .font(.system(size: TypeScale.micro, weight: .regular))
                      .foregroundStyle(Color.textTertiary)
                      .lineLimit(2)
                      .multilineTextAlignment(.leading)
                      .frame(maxWidth: .infinity, alignment: .leading)
                  }
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, Spacing.sm)
              .padding(.vertical, Spacing.sm_)
              .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                  .fill(isSelected ? Color.statusQuestion.opacity(OpacityTier.medium) : Color.clear)
              )
              .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                  .strokeBorder(
                    isSelected
                      ? Color.statusQuestion.opacity(OpacityTier.strong)
                      : Color.surfaceBorder.opacity(OpacityTier.subtle),
                    lineWidth: isSelected ? 1.5 : 1
                  )
              )
            }
            .buttonStyle(.plain)
          }
        }
      }

      // ━━━ Free-form input ━━━
      if prompt.options.isEmpty || prompt.allowsOther {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          if prompt.allowsOther, !prompt.options.isEmpty {
            Text("Or type your own response.")
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(Color.textTertiary)
          }

          pendingPromptDraftInput(prompt)
        }
      }
    }
  }

  func pendingPromptInstructionText(_ prompt: ApprovalQuestionPrompt) -> String {
    if prompt.allowsMultipleSelection {
      return "Select all that apply"
    }
    if prompt.allowsOther {
      return "Choose an option or type your own"
    }
    return "Choose one"
  }

  @ViewBuilder
  func pendingPromptDraftInput(_ prompt: ApprovalQuestionPrompt) -> some View {
    let draftBinding = Binding(
      get: { pendingPanelDrafts[prompt.id] ?? "" },
      set: { pendingPanelDrafts[prompt.id] = $0 }
    )

    if prompt.isSecret {
      SecureField("Secure response", text: draftBinding)
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
    } else {
      ZStack(alignment: .topLeading) {
        if (pendingPanelDrafts[prompt.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text("Your response")
            .font(.system(size: TypeScale.caption, weight: .regular))
            .foregroundStyle(Color.textQuaternary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.sm)
            .allowsHitTesting(false)
        }

        TextEditor(text: draftBinding)
          .font(.system(size: TypeScale.caption, weight: .regular))
          .foregroundStyle(Color.textPrimary)
          .scrollContentBackground(.hidden)
          .padding(.horizontal, Spacing.xs)
          .padding(.vertical, Spacing.xs)
      }
      .frame(minHeight: isCompactLayout ? 68 : 80)
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(Color.backgroundCode)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .strokeBorder(Color.statusQuestion.opacity(OpacityTier.subtle), lineWidth: 1)
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

  @ViewBuilder
  func pendingTakeOverContent(_ model: ApprovalCardModel) -> some View {
    Text("This session requires manual takeover before continuing.")
      .font(.system(size: TypeScale.caption, weight: .medium))
      .foregroundStyle(Color.textSecondary)
      .fixedSize(horizontal: false, vertical: true)

    Button(ApprovalCardConfiguration.takeoverButtonTitle(for: model)) {
      serverState.takeoverSession(model.sessionId)
    }
    .buttonStyle(CosmicButtonStyle(color: .accent))
  }

  func resetPendingPanelStateForRequest() {
    pendingPanelExpanded = true
    pendingPanelPromptIndex = 0
    pendingPanelAnswers = [:]
    pendingPanelDrafts = [:]
    pendingPanelShowDenyReason = false
    pendingPanelDenyReason = ""
  }

  func normalizedApprovalRequestId(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  func pendingToggleAnswer(
    questionId: String,
    optionLabel: String,
    allowsMultipleSelection: Bool
  ) {
    var values = pendingPanelAnswers[questionId] ?? []
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
      pendingPanelAnswers.removeValue(forKey: questionId)
    } else {
      pendingPanelAnswers[questionId] = values
    }
  }

  func pendingPromptIsAnswered(_ prompt: ApprovalQuestionPrompt) -> Bool {
    let hasSelectedOption = !(pendingPanelAnswers[prompt.id] ?? []).isEmpty
    let hasDraft = !(pendingPanelDrafts[prompt.id] ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty
    return hasSelectedOption || hasDraft
  }

  func pendingAllPromptsAnswered(_ prompts: [ApprovalQuestionPrompt]) -> Bool {
    prompts.allSatisfy { pendingPromptIsAnswered($0) }
  }

  func pendingCollectedAnswers(prompts: [ApprovalQuestionPrompt]) -> [String: [String]] {
    var answers: [String: [String]] = [:]
    for prompt in prompts {
      var values = pendingPanelAnswers[prompt.id] ?? []
      let draft = (pendingPanelDrafts[prompt.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if !draft.isEmpty, !values.contains(draft) {
        values.append(draft)
      }
      if !values.isEmpty {
        answers[prompt.id] = values
      }
    }
    return answers
  }

  func sendPendingQuestionAnswers(model: ApprovalCardModel, prompts: [ApprovalQuestionPrompt]) {
    guard let requestId = model.approvalId else { return }
    let answers = pendingCollectedAnswers(prompts: prompts)
    guard !answers.isEmpty else { return }

    let primaryQuestionId = prompts.first?.id
    let primaryAnswer: String? = {
      if let primaryQuestionId, let value = answers[primaryQuestionId]?.first {
        return value
      }
      for prompt in prompts {
        if let value = answers[prompt.id]?.first {
          return value
        }
      }
      return answers.values.first?.first
    }()
    guard let primaryAnswer, !primaryAnswer.isEmpty else { return }

    serverState.answerQuestion(
      sessionId: model.sessionId,
      requestId: requestId,
      answer: primaryAnswer,
      questionId: primaryQuestionId,
      answers: answers
    )
  }

  func sendPendingDecision(
    model: ApprovalCardModel,
    decision: String,
    message: String?,
    interrupt: Bool?
  ) {
    guard let requestId = model.approvalId else { return }
    serverState.approveTool(
      sessionId: model.sessionId,
      requestId: requestId,
      decision: decision,
      message: message,
      interrupt: interrupt
    )
  }
}
