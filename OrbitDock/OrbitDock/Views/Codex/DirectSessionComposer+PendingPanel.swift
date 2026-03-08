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

private struct PendingPanelContentHeightPreferenceKey: PreferenceKey {
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

    VStack(spacing: 0) {
      // Inline header (tap to collapse/expand)
      Button {
        withAnimation(Motion.standard) {
          pendingPanelExpanded.toggle()
        }
        Platform.services.playHaptic(.expansion)
      } label: {
        pendingInlineHeader(model, header: header, modeColor: modeColor)
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

      // Expandable content
      if pendingPanelExpanded {
        ScrollView(.vertical, showsIndicators: true) {
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
          .background(
            GeometryReader { geometry in
              Color.clear.preference(
                key: PendingPanelContentHeightPreferenceKey.self,
                value: geometry.size.height
              )
            }
          )
        }
        .frame(height: pendingPanelClampedContentHeight(for: model))
        .onPreferenceChange(PendingPanelContentHeightPreferenceKey.self) { measuredHeight in
          let normalizedHeight = max(0, measuredHeight)
          guard abs(normalizedHeight - pendingPanelMeasuredContentHeight) > 0.5 else { return }
          pendingPanelMeasuredContentHeight = normalizedHeight
        }
        .transition(.opacity.animation(Motion.gentle.delay(0.05)))
      }

      // Divider between pending zone and text input
      Rectangle()
        .fill(modeColor.opacity(OpacityTier.light))
        .frame(height: 0.5)
        .padding(.horizontal, Spacing.sm)
    }
  }

  // MARK: - Inline Header

  private func pendingInlineHeader(
    _ model: ApprovalCardModel,
    header: ApprovalHeaderConfig,
    modeColor: Color
  ) -> some View {
    HStack(spacing: Spacing.sm_) {
      Image(systemName: header.iconName)
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(header.iconTint)
        .frame(width: 16, height: 16)
        .background(
          RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(header.iconTint.opacity(OpacityTier.light))
        )

      Text(pendingPanelTitle(model))
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textPrimary)

      pendingHeaderChip(
        text: pendingPanelStatusBadgeText(model),
        tint: modeColor
      )

      if model.mode == .question, model.questions.count > 1 {
        pendingHeaderChip(
          text: "\(model.questions.count) prompts",
          tint: Color.statusQuestion
        )
      }

      let queueCount = serverState.queuedApprovalCount(sessionId: model.sessionId)
      if queueCount > 0 {
        pendingHeaderChip(
          text: "+\(queueCount) queued",
          tint: Color.textTertiary
        )
      }

      Spacer(minLength: 0)

      Image(systemName: "chevron.right")
        .font(.system(size: TypeScale.mini, weight: .bold))
        .foregroundStyle(Color.textQuaternary)
        .frame(width: 16, height: 16)
        .background(Circle().fill(Color.surfaceHover.opacity(OpacityTier.subtle)))
        .rotationEffect(.degrees(pendingPanelExpanded ? 90 : 0))
        .animation(Motion.snappy, value: pendingPanelExpanded)
    }
    .padding(.horizontal, Spacing.md_)
    .padding(.vertical, Spacing.xs)
    .background(
      pendingPanelHovering ? Color.surfaceHover : modeColor.opacity(OpacityTier.tint)
    )
    .contentShape(Rectangle())
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

  private func pendingPanelStatusBadgeText(_ model: ApprovalCardModel) -> String {
    switch model.mode {
      case .permission:
        "APPROVAL"
      case .question:
        "QUESTION"
      case .takeover:
        "TAKEOVER"
      case .none:
        ""
    }
  }

  @ViewBuilder
  private func pendingHeaderChip(text: String, tint: Color) -> some View {
    if !text.isEmpty {
      Text(text)
        .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
        .foregroundStyle(tint)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .background(
          Capsule().fill(tint.opacity(OpacityTier.light))
        )
    }
  }

  private func pendingPanelContentMaxHeight() -> CGFloat {
    isCompactLayout ? 220 : 260
  }

  private func pendingPanelFallbackHeight(for model: ApprovalCardModel) -> CGFloat {
    switch model.mode {
      case .permission:
        pendingPanelShowDenyReason ? 116 : 96
      case .question:
        152
      case .takeover:
        72
      case .none:
        44
    }
  }

  private func pendingPanelClampedContentHeight(for model: ApprovalCardModel) -> CGFloat {
    let measuredHeight = pendingPanelMeasuredContentHeight > 0
      ? pendingPanelMeasuredContentHeight
      : pendingPanelFallbackHeight(for: model)
    return min(pendingPanelContentMaxHeight(), measuredHeight)
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
            pendingCommandCodeBlock(segment: segment, modeColor: modeColor)
          } else {
            pendingCommandChainRow(index: index + 1, segment: segment, modeColor: modeColor)
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
      VStack(alignment: .leading, spacing: Spacing.sm_) {
        ForEach(Array(model.riskFindings.enumerated()), id: \.offset) { _, finding in
          HStack(alignment: .top, spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(model.risk.tintColor)
            Text(finding)
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(Color.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
              .multilineTextAlignment(.leading)
          }
        }
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.sm_)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(model.risk == .high ? Color.statusError.opacity(OpacityTier.tint) : Color.clear)
      )
    }

    // ━━━ Decision scope hint ━━━
    if let scope = model.decisionScope, !scope.isEmpty {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "info.circle")
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(Color.textQuaternary)
        Text(scope)
          .font(.system(size: TypeScale.micro, weight: .regular))
          .foregroundStyle(Color.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }

    // ━━━ Amendment detail (what "Always Allow" would permit) ━━━
    if model.hasAmendment, let detail = model.amendmentDetail, !detail.isEmpty {
      HStack(alignment: .top, spacing: Spacing.xs) {
        Image(systemName: "shield.checkered")
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.feedbackCaution)
        Text(detail)
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .multilineTextAlignment(.leading)
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.sm_)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(Color.feedbackCaution.opacity(OpacityTier.tint))
      )
    }

    // ━━━ Deny reason text field (cancel/send buttons in footer) ━━━
    if pendingPanelShowDenyReason {
      TextField("Deny reason", text: $pendingPanelDenyReason)
        .textFieldStyle(.plain)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textPrimary)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm_)
        .background(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(Color.backgroundCode)
        )
        .overlay(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(Color.feedbackNegative.opacity(OpacityTier.subtle), lineWidth: 1)
        )
    }
  }

  /// Standalone code block for single-step commands.
  func pendingCommandCodeBlock(segment: ApprovalShellSegment, modeColor: Color) -> some View {
    let codeRadius = isCompactLayout ? Radius.sm : Radius.md
    let codeFontSize = isCompactLayout ? TypeScale.micro : TypeScale.caption

    return ScrollView(.horizontal, showsIndicators: false) {
      Text(verbatim: segment.command)
        .font(.system(size: codeFontSize, weight: .regular, design: .monospaced))
        .foregroundStyle(Color.textPrimary)
        .lineSpacing(isCompactLayout ? 2 : 3)
        .fixedSize(horizontal: true, vertical: true)
        .multilineTextAlignment(.leading)
        .textSelection(.enabled)
        .padding(.horizontal, isCompactLayout ? Spacing.sm : Spacing.md_)
        .padding(.vertical, isCompactLayout ? Spacing.xs : Spacing.sm_)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: codeRadius, style: .continuous)
        .fill(Color.backgroundCode)
        .overlay(
          RoundedRectangle(cornerRadius: codeRadius, style: .continuous)
            .fill(modeColor.opacity(OpacityTier.tint))
        )
    )
    .overlay(
      RoundedRectangle(cornerRadius: codeRadius, style: .continuous)
        .strokeBorder(modeColor.opacity(OpacityTier.light), lineWidth: 0.5)
    )
  }

  /// Multi-step command chain row with numbered badge and operator label.
  func pendingCommandChainRow(
    index: Int,
    segment: ApprovalShellSegment,
    modeColor: Color
  ) -> some View {
    let operatorText = segment.leadingOperator?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    let chainCodeFont = isCompactLayout ? TypeScale.micro : TypeScale.caption

    return VStack(alignment: .leading, spacing: isCompactLayout ? Spacing.xxs : Spacing.sm_) {
      HStack(spacing: Spacing.xs) {
        Text("\(index)")
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(modeColor)
          .frame(width: 12, height: 12)
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
          .font(.system(size: chainCodeFont, weight: .regular, design: .monospaced))
          .foregroundStyle(Color.textPrimary)
          .lineSpacing(isCompactLayout ? 2 : 3)
          .fixedSize(horizontal: true, vertical: true)
          .multilineTextAlignment(.leading)
          .textSelection(.enabled)
          .padding(.horizontal, isCompactLayout ? Spacing.sm : Spacing.md_)
          .padding(.vertical, isCompactLayout ? Spacing.xs : Spacing.sm_)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .fill(Color.backgroundCode)
          .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              .fill(modeColor.opacity(OpacityTier.tint))
          )
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .strokeBorder(modeColor.opacity(OpacityTier.light), lineWidth: 0.5)
      )
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
            get: { pendingPanelDrafts["default"] ?? "" },
            set: { pendingPanelDrafts["default"] = $0 }
          )
        )
      }
    } else {
      let boundedIndex = min(max(pendingPanelPromptIndex, 0), max(0, prompts.count - 1))
      let prompt = prompts[boundedIndex]

      VStack(alignment: .leading, spacing: Spacing.sm) {
        // ━━━ Progress header (multi-question) ━━━
        if prompts.count > 1 {
          HStack(alignment: .center, spacing: Spacing.sm) {
            Text("Question \(boundedIndex + 1) of \(prompts.count)")
              .font(.system(size: TypeScale.micro, weight: .semibold))
              .foregroundStyle(Color.textTertiary)

            Spacer(minLength: 0)

            HStack(spacing: Spacing.xs) {
              ForEach(0 ..< prompts.count, id: \.self) { i in
                let dotColor: Color = pendingPromptIsAnswered(prompts[i])
                  ? .statusQuestion
                  : i == boundedIndex
                  ? Color.statusQuestion.opacity(0.4) : Color.textQuaternary.opacity(0.3)
                Circle()
                  .fill(dotColor)
                  .frame(width: 6, height: 6)
              }
            }
          }

          pendingQuestionMap(prompts: prompts, activeIndex: boundedIndex)
        }

        pendingPromptCard(prompt: prompt, index: boundedIndex, totalCount: prompts.count)
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
            }
            .foregroundStyle(
              isActive ? Color.textPrimary : answered ? Color.statusQuestion : Color.textSecondary
            )
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .cosmicBadge(
              color: isActive ? .statusQuestion : answered ? .statusQuestion : .textQuaternary,
              shape: .roundedRect,
              backgroundOpacity: isActive
                ? OpacityTier.medium : answered ? OpacityTier.subtle : OpacityTier.tint
            )
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  func pendingPromptCard(
    prompt: ApprovalQuestionPrompt,
    index: Int,
    totalCount: Int
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      // ━━━ Question text ━━━
      Text(prompt.question)
        .font(.system(size: TypeScale.body, weight: .semibold))
        .foregroundStyle(Color.textPrimary)
        .lineSpacing(2)
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
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                  if let description = option.description, !description.isEmpty {
                    Text(description)
                      .font(.system(size: TypeScale.micro, weight: .regular))
                      .foregroundStyle(Color.textTertiary)
                      .fixedSize(horizontal: false, vertical: true)
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
        if (pendingPanelDrafts[prompt.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty
        {
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
      if pendingPanelShowDenyReason {
        // Cancel deny reason
        Button {
          pendingPanelShowDenyReason = false
          pendingPanelDenyReason = ""
          Platform.services.playHaptic(.selection)
        } label: {
          Text("Cancel")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.textSecondary)
        }
        .buttonStyle(.plain)

        // Send denial
        let denyEmpty = pendingPanelDenyReason
          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        Button {
          let reason = pendingPanelDenyReason
            .trimmingCharacters(in: .whitespacesAndNewlines)
          guard !reason.isEmpty else { return }
          sendPendingDecision(
            model: model, decision: "denied", message: reason, interrupt: nil
          )
          pendingPanelShowDenyReason = false
          pendingPanelDenyReason = ""
        } label: {
          Image(systemName: "xmark")
            .font(.system(
              size: isCompactLayout ? TypeScale.subhead : TypeScale.caption,
              weight: .bold
            ))
            .foregroundStyle(.white)
            .frame(width: buttonSize, height: buttonSize)
            .background(
              Circle().fill(
                denyEmpty ? Color.surfaceHover : Color.feedbackNegative.opacity(0.85)
              )
            )
        }
        .buttonStyle(.plain)
        .disabled(denyEmpty)
      } else {
        // Deny
        Button {
          if let denyPrimary {
            if denyPrimary.decision == "deny_reason" {
              pendingPanelShowDenyReason = true
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
        Button {
          if let approvePrimary {
            sendPendingDecision(
              model: model, decision: approvePrimary.decision, message: nil, interrupt: nil
            )
          } else {
            sendPendingDecision(
              model: model, decision: "approved", message: nil, interrupt: nil
            )
          }
        } label: {
          Image(systemName: "checkmark")
            .font(.system(
              size: isCompactLayout ? TypeScale.subhead : TypeScale.caption,
              weight: .bold
            ))
            .foregroundStyle(.white)
            .frame(width: buttonSize, height: buttonSize)
            .background(Circle().fill(modeColor.opacity(0.85)))
        }
        .buttonStyle(.plain)

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
                      pendingPanelShowDenyReason = true
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
      let submitDisabled = (pendingPanelDrafts["default"] ?? "")
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

        Button {
          let answer = (pendingPanelDrafts["default"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
          guard let requestId = model.approvalId, !answer.isEmpty else { return }
          serverState.answerQuestion(
            sessionId: model.sessionId,
            requestId: requestId,
            answer: answer,
            questionId: nil,
            answers: nil
          )
        } label: {
          Image(systemName: "arrow.up")
            .font(.system(
              size: isCompactLayout ? TypeScale.subhead : TypeScale.caption,
              weight: .bold
            ))
            .foregroundStyle(.white)
            .frame(width: buttonSize, height: buttonSize)
            .background(
              Circle().fill(
                submitDisabled
                  ? Color.surfaceHover
                  : Color.statusQuestion.opacity(0.85)
              )
            )
        }
        .buttonStyle(.plain)
        .disabled(submitDisabled)
      }
    } else {
      let boundedIndex = min(
        max(pendingPanelPromptIndex, 0), max(0, prompts.count - 1)
      )
      let isLastQuestion = boundedIndex >= prompts.count - 1
      let prompt = prompts[boundedIndex]
      let isDisabled = isLastQuestion
        ? !pendingAllPromptsAnswered(prompts)
        : !pendingPromptIsAnswered(prompt)

      HStack(spacing: Spacing.sm_) {
        Button {
          sendPendingDecision(model: model, decision: "denied", message: "Dismissed", interrupt: nil)
        } label: {
          Text("Dismiss")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.textSecondary)
        }
        .buttonStyle(.plain)

        if prompts.count > 1 {
          Button {
            withAnimation(Motion.gentle) {
              pendingPanelPromptIndex = max(0, boundedIndex - 1)
            }
            Platform.services.playHaptic(.selection)
          } label: {
            Text("Back")
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.textSecondary)
          }
          .buttonStyle(.plain)
          .disabled(boundedIndex == 0)
          .opacity(boundedIndex == 0 ? 0.4 : 1.0)
        }

        Button {
          if !isLastQuestion {
            withAnimation(Motion.gentle) {
              pendingPanelPromptIndex = boundedIndex + 1
            }
            Platform.services.playHaptic(.selection)
          } else {
            sendPendingQuestionAnswers(model: model, prompts: prompts)
          }
        } label: {
          Image(systemName: isLastQuestion ? "arrow.up" : "arrow.right")
            .font(.system(
              size: isCompactLayout ? TypeScale.subhead : TypeScale.caption,
              weight: .bold
            ))
            .foregroundStyle(.white)
            .frame(width: buttonSize, height: buttonSize)
            .background(
              Circle().fill(
                isDisabled
                  ? Color.surfaceHover
                  : Color.statusQuestion.opacity(0.85)
              )
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
      }
    }
  }

  // MARK: Takeover Footer

  private func takeoverFooterActions(_ model: ApprovalCardModel) -> some View {
    Button {
      Platform.services.playHaptic(.success)
      serverState.takeoverSession(model.sessionId)
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
    pendingPanelExpanded = true
    pendingPanelPromptIndex = 0
    pendingPanelAnswers = [:]
    pendingPanelDrafts = [:]
    pendingPanelShowDenyReason = false
    pendingPanelDenyReason = ""
    pendingPanelMeasuredContentHeight = 0
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
    Platform.services.playHaptic(.selection)
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

  func pendingCollectedAnswers(
    prompts: [ApprovalQuestionPrompt]
  ) -> [String: [String]] {
    var answers: [String: [String]] = [:]
    for prompt in prompts {
      var values = pendingPanelAnswers[prompt.id] ?? []
      let draft = (pendingPanelDrafts[prompt.id] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !draft.isEmpty, !values.contains(draft) {
        values.append(draft)
      }
      if !values.isEmpty {
        answers[prompt.id] = values
      }
    }
    return answers
  }

  func sendPendingQuestionAnswers(
    model: ApprovalCardModel,
    prompts: [ApprovalQuestionPrompt]
  ) {
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

    let result = serverState.answerQuestion(
      sessionId: model.sessionId,
      requestId: requestId,
      answer: primaryAnswer,
      questionId: primaryQuestionId,
      answers: answers
    )
    switch result {
      case .dispatched:
        Platform.services.playHaptic(.success)
      case .stale:
        Platform.services.playHaptic(.warning)
    }
  }

  func sendPendingDecision(
    model: ApprovalCardModel,
    decision: String,
    message: String?,
    interrupt: Bool?
  ) {
    guard let requestId = model.approvalId else { return }
    let result = serverState.approveTool(
      sessionId: model.sessionId,
      requestId: requestId,
      decision: decision,
      message: message,
      interrupt: interrupt
    )
    switch result {
      case .dispatched:
        Platform.services.playHaptic(hapticForPendingDecision(decision))
      case .stale:
        Platform.services.playHaptic(.warning)
        approvalLog.warning("[approval] decision returned stale for \(requestId)")
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
