import SwiftUI

struct PendingPanelInlineHeader: View {
  let title: String
  let statusText: String
  let promptCountText: String?
  let header: ApprovalHeaderConfig
  let modeColor: Color
  let isExpanded: Bool
  let isHovering: Bool
  let onToggle: () -> Void
  let onHoverChanged: (Bool) -> Void

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: Spacing.sm_) {
        Image(systemName: header.iconName)
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(header.iconTint)
          .frame(width: 16, height: 16)
          .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              .fill(header.iconTint.opacity(OpacityTier.light))
          )

        Text(title)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textPrimary)

        PendingPanelHeaderChip(text: statusText, tint: modeColor)

        if let promptCountText {
          PendingPanelHeaderChip(text: promptCountText, tint: Color.statusQuestion)
        }

        Spacer(minLength: 0)

        Image(systemName: "chevron.right")
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(Color.textQuaternary)
          .frame(width: 16, height: 16)
          .background(Circle().fill(Color.surfaceHover.opacity(OpacityTier.subtle)))
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .animation(Motion.snappy, value: isExpanded)
      }
      .padding(.horizontal, Spacing.md_)
      .padding(.vertical, Spacing.xs)
      .background(
        isHovering ? Color.surfaceHover : modeColor.opacity(OpacityTier.tint)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover(perform: onHoverChanged)
  }
}

struct PendingPanelHeaderChip: View {
  let text: String
  let tint: Color

  var body: some View {
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
}

struct PendingCommandCodeBlock: View {
  let command: String
  let modeColor: Color
  let isCompactLayout: Bool

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      Text(verbatim: command)
        .font(.system(
          size: isCompactLayout ? TypeScale.micro : TypeScale.caption,
          weight: .regular,
          design: .monospaced
        ))
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
      RoundedRectangle(cornerRadius: isCompactLayout ? Radius.sm : Radius.md, style: .continuous)
        .fill(Color.backgroundCode)
        .overlay(
          RoundedRectangle(cornerRadius: isCompactLayout ? Radius.sm : Radius.md, style: .continuous)
            .fill(modeColor.opacity(OpacityTier.tint))
        )
    )
    .overlay(
      RoundedRectangle(cornerRadius: isCompactLayout ? Radius.sm : Radius.md, style: .continuous)
        .strokeBorder(modeColor.opacity(OpacityTier.light), lineWidth: 0.5)
    )
  }
}

struct PendingCommandChainRow: View {
  let index: Int
  let segment: ApprovalShellSegment
  let modeColor: Color
  let isCompactLayout: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: isCompactLayout ? Spacing.xxs : Spacing.sm_) {
      HStack(spacing: Spacing.xs) {
        Text("\(index)")
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(modeColor)
          .frame(width: 12, height: 12)
          .background(
            Circle()
              .fill(modeColor.opacity(OpacityTier.light))
          )

        if let operatorText = normalizedLeadingOperator, index > 1 {
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
          .font(.system(
            size: isCompactLayout ? TypeScale.micro : TypeScale.caption,
            weight: .regular,
            design: .monospaced
          ))
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

  private var normalizedLeadingOperator: String? {
    segment.leadingOperator?.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct PendingRiskFindingsSection: View {
  let findings: [String]
  let tint: Color
  let highlightsBackground: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
        HStack(alignment: .top, spacing: Spacing.xs) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(tint)
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
        .fill(highlightsBackground ? Color.statusError.opacity(OpacityTier.tint) : Color.clear)
    )
  }
}

struct PendingInfoHintRow: View {
  let iconName: String
  let iconColor: Color
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.xs) {
      Image(systemName: iconName)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(iconColor)
      Text(text)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.leading)
    }
  }
}

struct PendingDenyReasonField: View {
  let text: Binding<String>

  var body: some View {
    TextField("Deny reason", text: text)
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

struct DirectSessionComposerPendingQuestionContent: View {
  let prompts: [ApprovalQuestionPrompt]
  let activeIndex: Int
  let isCompactLayout: Bool
  let answeredState: [Bool]
  let answers: [String: [String]]
  let drafts: [String: String]
  let onSelectPrompt: (Int) -> Void
  let onToggleOption: (String, String, Bool) -> Void
  let onAdvanceAfterSingleSelection: () -> Void
  let onDraftChanged: (String, String) -> Void

  var body: some View {
    if prompts.isEmpty {
      EmptyView()
    } else {
      let boundedIndex = min(max(activeIndex, 0), max(0, prompts.count - 1))
      let prompt = prompts[boundedIndex]

      VStack(alignment: .leading, spacing: Spacing.sm) {
        if prompts.count > 1 {
          DirectSessionComposerPendingQuestionProgress(
            currentIndex: boundedIndex,
            totalCount: prompts.count,
            isCompactLayout: isCompactLayout,
            dotColors: (0 ..< prompts.count).map { index in
              answeredState[index]
                ? .statusQuestion
                : index == boundedIndex
                ? Color.statusQuestion.opacity(0.4)
                : Color.textQuaternary.opacity(0.3)
            }
          )

          DirectSessionComposerPendingQuestionMap(
            prompts: prompts,
            activeIndex: boundedIndex,
            answeredState: answeredState,
            onSelectPrompt: onSelectPrompt
          )
        }

        DirectSessionComposerPendingPromptCard(
          prompt: prompt,
          index: boundedIndex,
          totalCount: prompts.count,
          isCompactLayout: isCompactLayout,
          selectedAnswers: answers[prompt.id] ?? [],
          draft: drafts[prompt.id] ?? "",
          onToggleOption: { optionLabel in
            onToggleOption(prompt.id, optionLabel, prompt.allowsMultipleSelection)
            if !prompt.allowsMultipleSelection, !prompt.allowsOther, boundedIndex < prompts.count - 1 {
              onAdvanceAfterSingleSelection()
            }
          },
          onDraftChanged: { onDraftChanged(prompt.id, $0) }
        )
      }
    }
  }
}

private struct DirectSessionComposerPendingQuestionMap: View {
  let prompts: [ApprovalQuestionPrompt]
  let activeIndex: Int
  let answeredState: [Bool]
  let onSelectPrompt: (Int) -> Void

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.xs) {
        ForEach(Array(prompts.enumerated()), id: \.offset) { index, prompt in
          let answered = answeredState[index]
          let header = prompt.header?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Q\(index + 1)"
          let isActive = index == activeIndex

          Button {
            onSelectPrompt(index)
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
}

private struct DirectSessionComposerPendingPromptCard: View {
  let prompt: ApprovalQuestionPrompt
  let index: Int
  let totalCount: Int
  let isCompactLayout: Bool
  let selectedAnswers: [String]
  let draft: String
  let onToggleOption: (String) -> Void
  let onDraftChanged: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text(prompt.question)
        .font(.system(size: TypeScale.body, weight: .semibold))
        .foregroundStyle(Color.textPrimary)
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.leading)

      if !prompt.options.isEmpty {
        Text(promptInstructionText)
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textTertiary)

        VStack(spacing: Spacing.xs) {
          ForEach(Array(prompt.options.enumerated()), id: \.offset) { _, option in
            DirectSessionComposerPendingQuestionOptionRow(
              option: option,
              isSelected: selectedAnswers.contains(option.label)
            ) {
              onToggleOption(option.label)
            }
          }
        }
      }

      if prompt.options.isEmpty || prompt.allowsOther {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          if prompt.allowsOther, !prompt.options.isEmpty {
            Text("Or type your own response.")
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(Color.textTertiary)
          }

          DirectSessionComposerPendingPromptDraftInput(
            prompt: prompt,
            draft: draft,
            isCompactLayout: isCompactLayout,
            onDraftChanged: onDraftChanged
          )
        }
      }
    }
  }

  private var promptInstructionText: String {
    if prompt.allowsMultipleSelection {
      return "Select all that apply"
    }
    if prompt.allowsOther {
      return "Choose an option or type your own"
    }
    return "Choose one"
  }
}

private struct DirectSessionComposerPendingPromptDraftInput: View {
  let prompt: ApprovalQuestionPrompt
  let draft: String
  let isCompactLayout: Bool
  let onDraftChanged: (String) -> Void

  var body: some View {
    if prompt.isSecret {
      SecureField(
        "Secure response",
        text: Binding(get: { draft }, set: onDraftChanged)
      )
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
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text("Your response")
            .font(.system(size: TypeScale.caption, weight: .regular))
            .foregroundStyle(Color.textQuaternary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.sm)
            .allowsHitTesting(false)
        }

        TextEditor(text: Binding(get: { draft }, set: onDraftChanged))
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
}

struct DirectSessionComposerPendingQuestionFooter: View {
  let prompts: [ApprovalQuestionPrompt]
  let activeIndex: Int
  let submitDisabled: Bool
  let isCompactLayout: Bool
  let onDismiss: () -> Void
  let onBack: () -> Void
  let onAdvance: () -> Void
  let onSubmit: () -> Void

  var body: some View {
    let buttonSize: CGFloat = isCompactLayout ? 34 : 28

    HStack(spacing: Spacing.sm_) {
      Button(action: onDismiss) {
        Text("Dismiss")
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(Color.textSecondary)
      }
      .buttonStyle(.plain)

      if prompts.count > 1 {
        Button(action: onBack) {
          Text("Back")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.textSecondary)
        }
        .buttonStyle(.plain)
        .disabled(activeIndex == 0)
        .opacity(activeIndex == 0 ? 0.4 : 1.0)
      }

      DirectSessionComposerPendingFooterIconButton(
        systemName: isLastQuestion ? "arrow.up" : "arrow.right",
        iconSize: isCompactLayout ? TypeScale.subhead : TypeScale.caption,
        dimension: buttonSize,
        fillColor: submitDisabled ? Color.surfaceHover : Color.statusQuestion.opacity(0.85),
        isDisabled: submitDisabled,
        action: isLastQuestion ? onSubmit : onAdvance
      )
    }
  }

  private var isLastQuestion: Bool {
    activeIndex >= prompts.count - 1
  }
}

struct DirectSessionComposerPendingPermissionFooter: View {
  let state: DirectSessionComposerPendingPermissionFooterState
  let alternateDenyActions: [ApprovalCardConfiguration.MenuAction]
  let alternateApproveActions: [ApprovalCardConfiguration.MenuAction]
  let buttonSize: CGFloat
  let modeColor: Color
  let isCompactLayout: Bool
  let onCancelDenyReason: () -> Void
  let onSubmitDenyReason: () -> Void
  let onPrimaryDeny: () -> Void
  let onPrimaryApprove: () -> Void
  let onOverflowAction: (ApprovalCardConfiguration.MenuAction) -> Void

  var body: some View {
    HStack(spacing: Spacing.sm_) {
      if state.showsDenyReason {
        Button(action: onCancelDenyReason) {
          Text("Cancel")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.textSecondary)
        }
        .buttonStyle(.plain)

        DirectSessionComposerPendingFooterIconButton(
          systemName: "xmark",
          iconSize: isCompactLayout ? TypeScale.subhead : TypeScale.caption,
          dimension: buttonSize,
          fillColor: state.denySubmitDisabled ? Color.surfaceHover : Color.feedbackNegative.opacity(0.85),
          isDisabled: state.denySubmitDisabled,
          action: onSubmitDenyReason
        )
      } else {
        Button(action: onPrimaryDeny) {
          Text(state.primaryDenyAction?.title ?? "Deny")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.feedbackNegative)
        }
        .buttonStyle(.plain)

        DirectSessionComposerPendingFooterIconButton(
          systemName: "checkmark",
          iconSize: isCompactLayout ? TypeScale.subhead : TypeScale.caption,
          dimension: buttonSize,
          fillColor: modeColor.opacity(0.85),
          isDisabled: false,
          action: onPrimaryApprove
        )

        if state.hasOverflowActions {
          Menu {
            if !alternateDenyActions.isEmpty {
              Section("Deny") {
                ForEach(alternateDenyActions, id: \.self) { action in
                  Button(role: action.isDestructive ? .destructive : nil) {
                    onOverflowAction(action)
                  } label: {
                    Label(action.title, systemImage: action.iconName ?? "xmark")
                  }
                }
              }
            }

            if !alternateApproveActions.isEmpty {
              Section("Approve") {
                ForEach(alternateApproveActions, id: \.self) { action in
                  Button {
                    onOverflowAction(action)
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
}

struct DirectSessionComposerPendingTakeoverFooter: View {
  let title: String
  let onTakeover: () -> Void

  var body: some View {
    Button(action: onTakeover) {
      Text(title)
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
}
