import SwiftUI

struct ControlDeckApprovalZone: View {
  let approval: ControlDeckApproval
  let onApprove: () -> Void
  let onApproveForSession: () -> Void
  let onDeny: () -> Void
  let onAnswer: (String, String?) -> Void
  let onGrantPermission: () -> Void
  let onGrantPermissionForSession: () -> Void
  let onDenyPermission: () -> Void

  @State private var answerDrafts: [String: String] = [:]

  /// Whether actions are shown in the status bar (not inline)
  private var actionsInStatusBar: Bool {
    switch approval.kind {
      case .tool, .patch, .permission: true
      case .question: false
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      header
      content
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm_)
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      // Badge + Title inline
      statusBadge(
        title: kindBadgeTitle,
        icon: headerIcon,
        tint: headerColor
      )

      Text(approval.title)
        .font(.system(size: TypeScale.subhead, weight: .semibold))
        .foregroundStyle(Color.textPrimary)
        .lineLimit(1)

      promptCountBadge

      Spacer(minLength: 0)

      // Risk indicator (if elevated)
      if approval.riskLevel.isElevated {
        riskBadge
      }
    }
  }

  @ViewBuilder
  private var riskBadge: some View {
    let isHigh = approval.riskLevel == .high
    HStack(spacing: Spacing.xxs) {
      Image(systemName: isHigh ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
        .font(.system(size: 9, weight: .semibold))
      Text(isHigh ? "High Risk" : "Review")
        .font(.system(size: TypeScale.mini, weight: .semibold))
    }
    .foregroundStyle(isHigh ? Color.statusError : Color.feedbackCaution)
  }

  private var headerIcon: String {
    switch approval.kind {
      case .tool: "terminal"
      case .patch: "doc.badge.plus"
      case .question: "questionmark.bubble"
      case .permission: "lock.shield"
    }
  }

  private var headerColor: Color {
    // Use risk level to tint tool/patch approvals
    if case .tool = approval.kind, approval.riskLevel == .high {
      return Color.statusError
    }
    if case .patch = approval.kind, approval.riskLevel == .high {
      return Color.statusError
    }

    switch approval.kind {
      case .tool: return Color.feedbackCaution
      case .patch: return Color.toolWrite
      case .question: return Color.statusQuestion
      case .permission: return Color.statusPermission
    }
  }

  private var kindBadgeTitle: String {
    switch approval.kind {
      case .tool: "Tool"
      case .patch: "Edit"
      case .question: "Question"
      case .permission: "Permission"
    }
  }

  @ViewBuilder
  private var promptCountBadge: some View {
    if case let .question(prompts) = approval.kind, prompts.count > 1 {
      Text("\(prompts.count) prompts")
        .font(.system(size: TypeScale.mini, weight: .semibold, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 2)
        .background(Color.backgroundTertiary, in: Capsule())
    }
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      // Risk findings (only if there are specific findings to show)
      if !approval.riskFindings.isEmpty {
        riskFindings
      }

      // Main content by type
      switch approval.kind {
        case let .tool(toolApproval):
          toolContent(toolApproval)
        case let .patch(patchApproval):
          patchContent(patchApproval)
        case let .question(prompts):
          questionContent(prompts: prompts)
        case let .permission(permissionApproval):
          permissionContent(permissionApproval)
      }
    }
  }

  // MARK: - Risk Findings

  @ViewBuilder
  private var riskFindings: some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      ForEach(approval.riskFindings, id: \.self) { finding in
        HStack(alignment: .top, spacing: Spacing.xs) {
          Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(approval.riskLevel == .high ? Color.statusError : Color.feedbackCaution)
          Text(finding)
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.textSecondary)
            .lineLimit(2)
        }
      }
    }
  }

  // MARK: - Tool Content

  private func toolContent(_ tool: ControlDeckApproval.ToolApproval) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      // Command chain (multi-step) or single command
      if tool.commandChain.count > 1 {
        commandChainCard(tool.commandChain)
      } else if let command = tool.command, !command.isEmpty {
        commandBlock(command)
      }

      // File path context (compact)
      if let filePath = tool.filePath, !filePath.isEmpty {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "folder")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
          Text(filePath)
            .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
    }
  }

  /// Standalone command block - no card wrapper for simple readability
  private func commandBlock(_ command: String) -> some View {
    Text(command)
      .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
      .foregroundStyle(Color.textPrimary)
      .lineLimit(6)
      .textSelection(.enabled)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.sm_)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
  }

  private func commandChainCard(_ chain: [ControlDeckApproval.CommandSegment]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "list.number")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(headerColor)
        Text("\(chain.count) steps")
          .font(.system(size: TypeScale.mini, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
      }

      VStack(alignment: .leading, spacing: Spacing.xs) {
        ForEach(chain) { segment in
          HStack(alignment: .top, spacing: Spacing.xs) {
            Text("\(segment.index + 1)")
              .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
              .frame(width: 14, alignment: .trailing)

            if let opLabel = segment.operatorLabel {
              Text(opLabel)
                .font(.system(size: TypeScale.mini, weight: .medium))
                .foregroundStyle(headerColor.opacity(0.7))
                .padding(.horizontal, Spacing.xxs)
                .padding(.vertical, 1)
                .background(headerColor.opacity(OpacityTier.subtle), in: RoundedRectangle(cornerRadius: Radius.xs))
            }

            Text(segment.command)
              .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textPrimary)
              .lineLimit(2)
              .textSelection(.enabled)
          }
        }
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.sm_)
      .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
  }

  // MARK: - Patch Content

  @ViewBuilder
  private func patchContent(_ patch: ControlDeckApproval.PatchApproval) -> some View {
    // Just show the diff - file name is already in the title
    if let diff = patch.diff, !diff.isEmpty {
      ControlDeckApprovalDiffPreview(diffString: diff)
    }
  }

  // MARK: - Question Content

  private func questionContent(prompts: [ControlDeckApproval.Prompt]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      ForEach(Array(prompts.enumerated()), id: \.element.id) { index, prompt in
        questionPromptView(prompt, index: index, total: prompts.count)
      }
    }
  }

  private func questionPromptView(_ prompt: ControlDeckApproval.Prompt, index: Int, total: Int) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      // Header for multi-prompt or when explicitly provided
      if total > 1 || prompt.header != nil {
        HStack(spacing: Spacing.xs) {
          if let header = prompt.header {
            Text(header)
              .font(.system(size: TypeScale.mini, weight: .semibold))
              .foregroundStyle(Color.statusQuestion)
          }
          if total > 1 {
            Text("(\(index + 1) of \(total))")
              .font(.system(size: TypeScale.mini, weight: .medium))
              .foregroundStyle(Color.textTertiary)
          }
        }
      }

      // Question text
      Text(prompt.question)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textPrimary)
        .lineLimit(6)
        .fixedSize(horizontal: false, vertical: true)

      // Answer input
      if prompt.isFreeForm {
        answerField(prompt: prompt)
      } else {
        questionOptions(prompt)
        if prompt.allowsOther {
          answerField(prompt: prompt, placeholder: "Or type a custom answer")
        }
      }
    }
  }

  private func questionOptions(_ prompt: ControlDeckApproval.Prompt) -> some View {
    VStack(spacing: Spacing.xxs) {
      ForEach(prompt.options) { option in
        Button {
          onAnswer(option.label, prompt.id)
        } label: {
          HStack(spacing: Spacing.xs) {
            Image(systemName: prompt.allowsMultipleSelection ? "square" : "circle")
              .font(.system(size: 9, weight: .medium))
              .foregroundStyle(Color.statusQuestion.opacity(0.6))

            VStack(alignment: .leading, spacing: 1) {
              Text(option.label)
                .font(.system(size: TypeScale.caption, weight: .medium))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)

              if let description = option.description {
                Text(description)
                  .font(.system(size: TypeScale.mini, weight: .regular))
                  .foregroundStyle(Color.textTertiary)
                  .lineLimit(1)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)
          .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
      }
    }
  }

  private func answerField(prompt: ControlDeckApproval.Prompt, placeholder: String = "Type your answer") -> some View {
    let text = Binding<String>(
      get: { answerDrafts[prompt.id] ?? "" },
      set: { answerDrafts[prompt.id] = $0 }
    )

    return HStack(spacing: Spacing.xs) {
      Group {
        if prompt.isSecret {
          SecureField(placeholder, text: text)
        } else {
          TextField(placeholder, text: text)
        }
      }
      .font(.system(size: TypeScale.caption))
      .textFieldStyle(.plain)

      Button {
        let answer = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        onAnswer(answer, prompt.id)
        answerDrafts[prompt.id] = ""
      } label: {
        Image(systemName: "arrow.up")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(submissionText(prompt.id).isEmpty ? Color.textQuaternary : Color.backgroundPrimary)
          .frame(width: 24, height: 24)
          .background(
            submissionText(prompt.id).isEmpty ? Color.backgroundTertiary : Color.statusQuestion,
            in: Circle()
          )
      }
      .buttonStyle(.plain)
      .disabled(submissionText(prompt.id).isEmpty)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
  }

  // MARK: - Permission Content

  private func permissionContent(_ permission: ControlDeckApproval.PermissionApproval) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      // Reason text (if provided)
      if let reason = permission.reason, !reason.isEmpty {
        Text(reason)
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(Color.textSecondary)
          .lineLimit(3)
      }

      // Permission groups
      ForEach(permission.groups) { group in
        permissionGroupView(group)
      }
    }
  }

  private func permissionGroupView(_ group: ControlDeckApproval.PermissionGroup) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: group.category.icon)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(Color.statusPermission)
        Text(group.category.title)
          .font(.system(size: TypeScale.mini, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
      }

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        ForEach(group.items) { item in
          HStack(alignment: .top, spacing: Spacing.xs) {
            Text(item.action.capitalized)
              .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
              .foregroundStyle(Color.statusPermission.opacity(0.8))
              .frame(width: 36, alignment: .leading)

            Text(item.target)
              .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textPrimary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.sm_)
      .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
  }

  // MARK: - Helpers

  private func statusBadge(title: String, icon: String, tint: Color) -> some View {
    HStack(spacing: Spacing.gap) {
      Image(systemName: icon)
        .font(.system(size: TypeScale.mini, weight: .semibold))

      Text(title.uppercased())
        .font(.system(size: TypeScale.mini, weight: .semibold, design: .monospaced))
    }
    .foregroundStyle(tint)
    .padding(.horizontal, Spacing.sm_)
    .padding(.vertical, Spacing.gap)
    .background(tint.opacity(OpacityTier.light), in: Capsule())
  }

  private func submissionText(_ promptId: String) -> String {
    answerDrafts[promptId]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }
}
