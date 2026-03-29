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
  @State private var appeared = false

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      header
      if let detail = trimmedDetail {
        summaryCard(detail)
      }
      content
      actions
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.md)
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 8)
    .onAppear {
      withAnimation(Motion.gentle) {
        appeared = true
      }
      #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      #endif
    }
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      HStack(spacing: Spacing.xs) {
        statusBadge(
          title: kindBadgeTitle,
          icon: headerIcon,
          tint: headerColor
        )

        promptCountBadge

        Spacer(minLength: 0)
      }

      Text(approval.title)
        .font(.system(size: TypeScale.title, weight: .semibold))
        .foregroundStyle(Color.textPrimary)
        .lineLimit(2)

      Text(guidanceText)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(3)
    }
  }

  private var headerIcon: String {
    switch approval.kind {
      case .tool: "terminal"
      case .question: "questionmark.bubble"
      case .permission: "lock.shield"
    }
  }

  private var headerColor: Color {
    switch approval.kind {
      case .tool: .feedbackCaution
      case .question: .accent
      case .permission: .statusPermission
    }
  }

  private var kindBadgeTitle: String {
    switch approval.kind {
      case .tool: "Review"
      case .question: "Question"
      case .permission: "Permission"
    }
  }

  private var guidanceText: String {
    switch approval.kind {
      case .tool:
        "Check the requested action before you approve it. Use the menu if you want to allow it for the whole session."
      case .question:
        "Answer the agent directly here so it can keep moving without leaving the deck."
      case .permission:
        "Review the requested access and decide whether to grant it once or for the rest of this session."
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
    switch approval.kind {
      case let .tool(_, command, filePath, diff):
        toolContent(command: command, filePath: filePath, diff: diff)
      case let .question(prompts):
        questionContent(prompts: prompts)
      case let .permission(reason, descriptions):
        permissionContent(reason: reason, descriptions: descriptions)
    }
  }

  private func toolContent(command: String?, filePath: String?, diff: String?) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      approvalCard(title: "Requested Action", icon: "terminal", tint: .feedbackCaution) {
        VStack(alignment: .leading, spacing: Spacing.sm_) {
          if let command, !command.isEmpty {
            metadataRow(title: "Command", value: command, multiLine: true)
          }
          if let filePath, !filePath.isEmpty {
            metadataRow(title: "Path", value: filePath, multiLine: false)
          }
        }
      }

      if let diff, !diff.isEmpty {
        ApprovalDiffPreview(diffString: diff)
      }
    }
  }

  private func questionContent(prompts: [ControlDeckApproval.Prompt]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      ForEach(Array(prompts.enumerated()), id: \.element.id) { index, prompt in
        approvalCard(
          title: prompts.count > 1 ? "Prompt \(index + 1)" : "Prompt",
          icon: "questionmark.bubble",
          tint: .statusQuestion
        ) {
          VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(prompt.question)
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.textPrimary)
              .lineLimit(6)

            if !prompt.options.isEmpty {
              questionOptions(prompt)
            } else {
              answerField(prompt: prompt)
            }
          }
        }
      }
    }
  }

  private func questionOptions(_ prompt: ControlDeckApproval.Prompt) -> some View {
    VStack(spacing: Spacing.xxs) {
      ForEach(prompt.options, id: \.self) { option in
        Button {
          onAnswer(option, prompt.id)
        } label: {
          HStack(spacing: Spacing.sm_) {
            Image(systemName: "arrow.turn.down.right")
              .font(.system(size: TypeScale.mini, weight: .semibold))
              .foregroundStyle(Color.statusQuestion.opacity(0.9))

            Text(option)
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.textPrimary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .lineLimit(2)
          }
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.sm_)
          .background(Color.backgroundPrimary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
              .strokeBorder(Color.statusQuestion.opacity(OpacityTier.light), lineWidth: 1)
          )
        }
        .buttonStyle(.plain)
      }
    }
  }

  private func answerField(prompt: ControlDeckApproval.Prompt) -> some View {
    let text = Binding<String>(
      get: { answerDrafts[prompt.id] ?? "" },
      set: { answerDrafts[prompt.id] = $0 }
    )

    return HStack(spacing: Spacing.sm) {
      Group {
        if prompt.isSecret {
          SecureField("Type your answer", text: text)
        } else {
          TextField("Type your answer", text: text)
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
          .font(.system(size: TypeScale.caption, weight: .bold))
          .foregroundStyle(submissionText(prompt.id).isEmpty ? Color.textQuaternary : Color.backgroundPrimary)
          .frame(width: 28, height: 28)
          .background(
            submissionText(prompt.id).isEmpty ? Color.backgroundPrimary : Color.statusQuestion,
            in: Circle()
          )
      }
      .buttonStyle(.plain)
      .disabled(submissionText(prompt.id).isEmpty)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .background(Color.backgroundPrimary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(Color.statusQuestion.opacity(OpacityTier.light), lineWidth: 1)
    )
  }

  private func permissionContent(reason: String?, descriptions: [String]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      if let reason, !reason.isEmpty {
        approvalCard(title: "Why access is needed", icon: "lock.shield", tint: .statusPermission) {
          Text(reason)
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(4)
        }
      }

      if !descriptions.isEmpty {
        approvalCard(title: "Requested Access", icon: "key.horizontal", tint: .statusPermission) {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(descriptions, id: \.self) { description in
              HStack(alignment: .top, spacing: Spacing.sm_) {
                Circle()
                  .fill(Color.statusPermission)
                  .frame(width: 6, height: 6)
                  .padding(.top, 4)

                Text(description)
                  .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
                  .foregroundStyle(Color.textSecondary)
                  .lineLimit(3)
              }
            }
          }
        }
      }
    }
  }

  // MARK: - Actions

  @ViewBuilder
  private var actions: some View {
    switch approval.kind {
      case .tool:
        decisionFooter(
          secondaryTitle: "Deny",
          secondaryTint: .textSecondary,
          secondaryAction: {
            onDeny()
            hapticDeny()
          },
          primaryTitle: "Approve Once",
          primaryTint: .feedbackPositive,
          primaryAction: {
            onApprove()
            hapticApprove()
          },
          menuActions: [
            ("Approve for Session", {
              onApproveForSession()
              hapticApprove()
            })
          ],
          footnote: "The primary action approves this request once. Use the menu if you want the approval to persist for the rest of the session."
        )
      case .question:
        EmptyView()
      case .permission:
        decisionFooter(
          secondaryTitle: "Deny",
          secondaryTint: .textSecondary,
          secondaryAction: {
            onDenyPermission()
            hapticDeny()
          },
          primaryTitle: "Grant Once",
          primaryTint: .statusPermission,
          primaryAction: {
            onGrantPermission()
            hapticApprove()
          },
          menuActions: [
            ("Grant for Session", {
              onGrantPermissionForSession()
              hapticApprove()
            })
          ],
          footnote: "Grant once when the access only makes sense for this step. Grant for session when you trust the rest of the work to need the same scope."
        )
    }
  }

  private func decisionFooter(
    secondaryTitle: String,
    secondaryTint: Color,
    secondaryAction: @escaping () -> Void,
    primaryTitle: String,
    primaryTint: Color,
    primaryAction: @escaping () -> Void,
    menuActions: [(String, () -> Void)],
    footnote: String
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      let stackedLayout = approvalButtonLayout == .stacked

      Group {
        if stackedLayout {
          VStack(spacing: Spacing.sm) {
            splitPrimaryActionButton(
              title: primaryTitle,
              tint: primaryTint,
              primaryAction: primaryAction,
              menuActions: menuActions
            )
            secondaryButton(title: secondaryTitle, tint: secondaryTint, action: secondaryAction)
          }
        } else {
          HStack(spacing: Spacing.sm) {
            secondaryButton(title: secondaryTitle, tint: secondaryTint, action: secondaryAction)
            splitPrimaryActionButton(
              title: primaryTitle,
              tint: primaryTint,
              primaryAction: primaryAction,
              menuActions: menuActions
            )
          }
        }
      }

      Text(footnote)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textTertiary)
        .lineLimit(3)
    }
  }

  private func splitPrimaryActionButton(
    title: String,
    tint: Color,
    primaryAction: @escaping () -> Void,
    menuActions: [(String, () -> Void)]
  ) -> some View {
    HStack(spacing: 0) {
      Button(action: primaryAction) {
        HStack(spacing: Spacing.sm_) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: TypeScale.caption, weight: .bold))

          Text(title)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .lineLimit(1)
        }
        .foregroundStyle(Color.backgroundPrimary)
        .frame(maxWidth: .infinity, minHeight: approvalButtonHeight)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if !menuActions.isEmpty {
        Rectangle()
          .fill(Color.backgroundPrimary.opacity(0.12))
          .frame(width: 1)

        Menu {
          ForEach(Array(menuActions.enumerated()), id: \.offset) { _, action in
            Button(action.0) { action.1() }
          }
        } label: {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "ellipsis.circle")
              .font(.system(size: TypeScale.caption, weight: .bold))
            #if os(iOS)
              if approvalButtonLayout == .stacked {
                Text("More")
                  .font(.system(size: TypeScale.caption, weight: .semibold))
              }
            #endif
          }
          .foregroundStyle(Color.backgroundPrimary)
          .frame(minWidth: approvalMenuWidth, minHeight: approvalButtonHeight)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .background(tint, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .strokeBorder(tint.opacity(0.95), lineWidth: 1)
    )
    .themeShadow(Shadow.glow(color: tint, intensity: 0.16))
  }

  private func secondaryButton(
    title: String,
    tint: Color,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: Spacing.sm_) {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: TypeScale.caption, weight: .bold))

        Text(title)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .lineLimit(1)

        Spacer(minLength: 0)
      }
      .foregroundStyle(tint)
      .padding(.horizontal, Spacing.md)
      .frame(maxWidth: .infinity, minHeight: approvalButtonHeight, alignment: .leading)
      .contentShape(Rectangle())
      .background(Color.backgroundPrimary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .strokeBorder(Color.panelBorder.opacity(OpacityTier.medium), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }

  private var approvalButtonHeight: CGFloat {
    #if os(iOS)
      46
    #else
      40
    #endif
  }

  private var approvalMenuWidth: CGFloat {
    #if os(iOS)
      approvalButtonLayout == .stacked ? 92 : 60
    #else
      44
    #endif
  }

  private var approvalButtonLayout: ApprovalButtonLayout {
    #if os(iOS)
      return .stacked
    #else
      return .inline
    #endif
  }

  private enum ApprovalButtonLayout {
    case inline
    case stacked
  }

  private func approvalCard<Content: View>(
    title: String,
    icon: String,
    tint: Color,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: icon)
          .font(.system(size: TypeScale.mini, weight: .semibold))
          .foregroundStyle(tint)

        Text(title)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textSecondary)
      }

      content()
    }
    .padding(Spacing.md)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .strokeBorder(tint.opacity(OpacityTier.light), lineWidth: 1)
    )
  }

  private func summaryCard(_ text: String) -> some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      Image(systemName: headerIcon)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(headerColor)
        .padding(.top, 1)

      Text(text)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(4)
    }
    .padding(Spacing.md)
    .background(headerColor.opacity(OpacityTier.light), in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
  }

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

  private func metadataRow(title: String, value: String, multiLine: Bool) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(title)
        .font(.system(size: TypeScale.mini, weight: .semibold, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
      Text(value)
        .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textPrimary)
        .lineLimit(multiLine ? 4 : 1)
        .textSelection(.enabled)
    }
  }

  private var trimmedDetail: String? {
    guard let detail = approval.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
          !detail.isEmpty
    else {
      return nil
    }
    return detail
  }

  private func submissionText(_ promptId: String) -> String {
    answerDrafts[promptId]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  // MARK: - Haptics

  private func hapticApprove() {
    #if os(iOS)
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    #endif
  }

  private func hapticDeny() {
    #if os(iOS)
      UINotificationFeedbackGenerator().notificationOccurred(.warning)
    #endif
  }
}
