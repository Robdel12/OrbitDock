import SwiftUI

enum ControlDeckSendClusterAction: Hashable {
  case interrupt
  case resume
  case send
}

enum ControlDeckSendClusterPlanner {
  static func actions(
    canInterruptSession: Bool,
    canSubmit: Bool,
    canResume: Bool
  ) -> [ControlDeckSendClusterAction] {
    if canInterruptSession {
      return canSubmit ? [.interrupt, .send] : [.interrupt]
    }

    if canResume {
      return [.resume]
    }

    return [.send]
  }
}

struct ControlDeckStatusBar: View {
  let modules: [ControlDeckStatusModuleItem]
  var onModuleAction: ((ControlDeckStatusModule, String) -> Void)?
  var onApprovalReviewerAction: ((ServerCodexApprovalsReviewer) -> Void)?
  var onSandboxPolicyAction: ((ServerCodexSandboxPolicy) -> Void)?

  // Action buttons
  var supportsImages: Bool = false
  var canPasteImage: Bool = false
  var canSubmit: Bool = false
  var canResume: Bool = false
  var isSubmitting: Bool = false
  var isResuming: Bool = false
  var sendTint: String = "accent"
  var isShellMode: Bool = false
  var supportsSessionShell: Bool = false
  var sessionShellAvailable: Bool = false
  var onAddImage: (() -> Void)?
  var onPasteImage: (() -> Void)?
  var onSubmit: (() -> Void)?
  var onToggleShellMode: (() -> Void)?
  var onResume: (() -> Void)?
  var isDictating: Bool = false
  var canInterruptSession: Bool = false
  var onDictation: (() -> Void)?
  var onInterrupt: (() -> Void)?
  var onTurnControlAction: ((String) -> Void)?

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var isCompact: Bool {
    horizontalSizeClass == .compact
  }

  private var minimumBarHeight: CGFloat {
    isCompact ? 38 : 28
  }

  private var actionButtonSize: CGFloat {
    isCompact ? 32 : 26
  }

  private var sendButtonSize: CGFloat {
    isCompact ? 34 : 28
  }

  private func isControlModule(_ module: ControlDeckStatusModuleItem) -> Bool {
    switch module.id {
      case .autonomy, .approvalMode, .collaborationMode, .autoReview, .effort, .model, .turnControls:
        return true
      default:
        return false
    }
  }

  var body: some View {
    HStack(spacing: isCompact ? Spacing.xs : Spacing.sm_) {
      // Action buttons (left edge)
      actionButtons

      // Scrollable status modules (fills middle)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: isCompact ? Spacing.xs : Spacing.sm) {
          if !controlModules.isEmpty {
            controlModuleRow(controlModules)
          }

          if !metadataModules.isEmpty {
            if !controlModules.isEmpty {
              divider
            }

            metadataModuleRow(metadataModules)
          }
        }
      }
      .scrollIndicators(.hidden)

      // Send cluster (right edge)
      sendCluster
    }
    .frame(minHeight: minimumBarHeight, alignment: .center)
  }

  // MARK: - Action Buttons

  private var actionButtons: some View {
    HStack(spacing: isCompact ? Spacing.xs : Spacing.xxs) {
      if supportsSessionShell {
        ghostButton(
          icon: "terminal",
          tint: isShellMode ? .composerShell : .terminal,
          isEnabled: sessionShellAvailable,
          action: { onToggleShellMode?() }
        )
      }

      if supportsImages {
        ghostButton(icon: "paperclip", tint: .accent, action: { onAddImage?() })
      }

      if let onDictation {
        ghostButton(
          icon: isDictating ? "stop.fill" : "mic.fill",
          tint: isDictating ? .statusError : .accent,
          action: onDictation
        )
      }
    }
  }

  // MARK: - Send Cluster

  private var sendCluster: some View {
    HStack(spacing: isCompact ? Spacing.xs : Spacing.sm_) {
      ForEach(sendClusterActions, id: \.self) { action in
        sendClusterButton(action)
      }
    }
  }

  private var sendClusterActions: [ControlDeckSendClusterAction] {
    ControlDeckSendClusterPlanner.actions(
      canInterruptSession: canInterruptSession,
      canSubmit: canSubmit,
      canResume: canResume
    )
  }

  @ViewBuilder
  private func sendClusterButton(_ action: ControlDeckSendClusterAction) -> some View {
    switch action {
      case .interrupt:
        interruptButton
      case .resume:
        resumeButton
      case .send:
        sendButton
    }
  }

  private var interruptButton: some View {
    Button(action: { onInterrupt?() }) {
      Image(systemName: "stop.fill")
        .font(.system(size: TypeScale.caption, weight: .bold))
        .frame(width: sendButtonSize, height: sendButtonSize)
        .foregroundStyle(Color.statusError)
        .background(Color.statusError.opacity(OpacityTier.light), in: Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Stop")
  }

  private var resumeButton: some View {
    Button(action: { onResume?() }) {
      HStack(spacing: Spacing.xxs) {
        if isResuming {
          ProgressView()
            .controlSize(.mini)
            .tint(Color.feedbackWarning)
        } else {
          Image(systemName: "play.fill")
            .font(.system(size: TypeScale.caption, weight: .bold))
        }
        Text("Resume")
          .font(.system(size: TypeScale.mini, weight: .semibold, design: .rounded))
          .lineLimit(1)
      }
      .foregroundStyle(Color.feedbackWarning)
      .padding(.horizontal, Spacing.sm)
      .frame(height: sendButtonSize)
      .background(
        Capsule()
          .fill(Color.feedbackWarning.opacity(OpacityTier.light))
          .overlay(
            Capsule()
              .strokeBorder(Color.feedbackWarning.opacity(0.25), lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
    .disabled(isResuming)
    .accessibilityLabel("Resume")
  }

  private var sendButton: some View {
    Button(action: { onSubmit?() }) {
      Group {
        if isSubmitting {
          ProgressView()
            .controlSize(.mini)
            .tint(.white)
        } else {
          Image(systemName: isShellMode ? "terminal.fill" : "arrow.up")
            .font(.system(size: TypeScale.caption, weight: .bold))
            .foregroundStyle(canSubmit ? Color.backgroundPrimary : Color.textQuaternary)
        }
      }
      .frame(width: sendButtonSize, height: sendButtonSize)
      .background(canSubmit ? resolvedSendTint : Color.backgroundTertiary, in: Circle())
    }
    .buttonStyle(.plain)
    .disabled(!canSubmit || isSubmitting)
    .accessibilityLabel(isShellMode ? "Run in Session" : "Send")
  }

  private var resolvedSendTint: Color {
    switch sendTint {
      case "accent": .accent
      case "composerShell": .composerShell
      case "feedbackWarning": .feedbackWarning
      case "feedbackCaution": .feedbackCaution
      case "feedbackPositive": .feedbackPositive
      default: .accent
    }
  }

  // MARK: - Module View

  @ViewBuilder
  private func moduleView(_ module: ControlDeckStatusModuleItem) -> some View {
    switch module.id {
      case .autonomy:
        ClaudePermissionPill(
          currentMode: ClaudePermissionMode(fromServer: module.selectedValue),
          size: .statusBar,
          onUpdate: { mode in
            onModuleAction?(module.id, permissionModeValue(mode, for: module))
          }
        )
      case .approvalMode:
        CodexApprovalPill(
          currentMode: CodexApprovalMode.from(rawValue: module.selectedValue),
          currentReviewer: CodexApprovalsReviewer.from(rawValue: module.reviewerValue),
          currentSandboxPolicy: module.sandboxPolicyDetails,
          supportedModes: CodexApprovalMode.supportedCases(from: pickerOptions(for: module)),
          size: .statusBar,
          onUpdate: { mode in
            onModuleAction?(module.id, approvalModeValue(mode, for: module))
          },
          onReviewerUpdate: { reviewer in
            onApprovalReviewerAction?(ServerCodexApprovalsReviewer(rawValue: reviewer.rawValue) ?? .user)
          },
          onSandboxUpdate: { policy in
            onSandboxPolicyAction?(policy)
          }
        )
      case .collaborationMode:
        CodexModePill(
          currentMode: CodexCollaborationMode.from(rawValue: module.selectedValue),
          supportedModes: codexCollaborationModes(for: module),
          size: .statusBar,
          onUpdate: { mode in
            onModuleAction?(module.id, collaborationModeValue(mode, for: module))
          }
        )
      case .autoReview:
        if let level = AutonomyLevel.fromAutoReviewValue(module.selectedValue) {
          CodexAutoReviewPill(
            currentLevel: level,
            supportedLevels: AutonomyLevel.supportedAutoReviewCases(from: pickerOptions(for: module)),
            size: .statusBar,
            onUpdate: { level in
              onModuleAction?(module.id, autoReviewValue(for: level))
            }
          )
        } else {
          genericModuleView(module)
        }
      case .effort:
        EffortPill(
          currentLevel: EffortLevel.fromControlDeckValue(module.selectedValue),
          supportedLevels: EffortLevel.supportedControlDeckCases(from: pickerOptions(for: module)),
          size: .statusBar,
          onUpdate: { level in
            onModuleAction?(module.id, effortValue(level, for: module))
          }
        )
      case .model:
        let options = pickerOptions(for: module)
        if !options.isEmpty {
          ModelPill(
            currentModel: module.selectedValue,
            availableModels: options.map(\.value),
            size: .statusBar,
            onUpdate: { model in
              onModuleAction?(module.id, model)
            }
          )
        } else {
          genericModuleView(module)
        }
      case .turnControls:
        turnControlsModuleView(module)
      default:
        genericModuleView(module)
    }
  }

  @ViewBuilder
  private func turnControlsModuleView(_ module: ControlDeckStatusModuleItem) -> some View {
    if case let .actions(items) = module.interaction, !items.isEmpty {
      Menu {
        ForEach(items) { item in
          Button(role: item.isDestructive ? .destructive : nil) {
            onTurnControlAction?(item.action)
          } label: {
            Label(item.label, systemImage: item.icon ?? "circle")
          }
          .disabled(!item.isEnabled)
        }
      } label: {
        turnControlsModuleLabel(module)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    } else {
      moduleLabel(module)
    }
  }

  private func turnControlsModuleLabel(_ module: ControlDeckStatusModuleItem) -> some View {
    HStack(spacing: Spacing.xxs) {
      Image(systemName: module.icon)
        .font(.system(size: IconScale.sm, weight: .semibold))
        .frame(width: 12)
        .foregroundStyle(tintColor(module.tintName))
      Text(module.label)
        .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .foregroundStyle(Color.textPrimary)
      Image(systemName: "chevron.up.chevron.down")
        .font(.system(size: IconScale.xs, weight: .semibold))
        .foregroundStyle(Color.textQuaternary)
    }
    .padding(.horizontal, Spacing.sm_)
    .padding(.vertical, Spacing.gap)
    .background(
      Color.backgroundTertiary.opacity(0.72),
      in: Capsule()
    )
  }

  @ViewBuilder
  private func genericModuleView(_ module: ControlDeckStatusModuleItem) -> some View {
    switch module.interaction {
      case .readOnly:
        moduleLabel(module)

      case let .picker(options):
        if options.isEmpty {
          moduleLabel(module)
            .opacity(0.85)
        } else {
          Menu {
            ForEach(options) { option in
              Button {
                onModuleAction?(module.id, option.value)
              } label: {
                HStack {
                  Text(option.label)
                  if option.value.caseInsensitiveCompare(module.selectedValue ?? "") == .orderedSame {
                    Image(systemName: "checkmark")
                  }
                }
              }
            }
          } label: {
            moduleLabel(module, interactive: true)
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
        }

      case .actions:
        // Actions are handled by custom module views, not generic
        moduleLabel(module)
    }
  }

  private func moduleLabel(_ module: ControlDeckStatusModuleItem, interactive: Bool = false) -> some View {
    let isFlatInteractive = interactive && module.id == .model
    return HStack(spacing: Spacing.xxs) {
      Image(systemName: module.icon)
        .font(.system(size: IconScale.sm, weight: .semibold))
        .frame(width: 12)
        .foregroundStyle(tintColor(module.tintName))
      Text(module.label)
        .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .foregroundStyle(moduleTextColor(module, interactive: interactive))
      if interactive {
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: IconScale.xs, weight: .semibold))
          .foregroundStyle(Color.textQuaternary)
      }
    }
    .padding(.horizontal, interactive ? Spacing.sm_ : 0)
    .padding(.vertical, interactive ? Spacing.gap : 0)
    .background(
      (interactive && !isFlatInteractive)
        ? Color.backgroundTertiary.opacity(0.72)
        : Color.clear,
      in: Capsule()
    )
  }

  // MARK: - Ghost Button

  private func ghostButton(
    icon: String,
    tint: Color,
    isEnabled: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: isCompact ? TypeScale.caption : TypeScale.subhead, weight: .semibold))
        .foregroundStyle(isEnabled ? tint : Color.textQuaternary)
        .frame(width: actionButtonSize, height: actionButtonSize)
        .background(
          (isEnabled ? tint : Color.backgroundTertiary).opacity(isEnabled ? OpacityTier.light : 0.08),
          in: Circle()
        )
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .accessibilityLabel(Text(icon))
  }

  private var divider: some View {
    Rectangle()
      .fill(Color.panelBorder.opacity(OpacityTier.medium))
      .frame(width: 1, height: 12)
  }

  private func controlModuleRow(_ modules: [ControlDeckStatusModuleItem]) -> some View {
    HStack(spacing: Spacing.xs) {
      ForEach(modules) { module in
        moduleView(module)
      }
    }
  }

  private func metadataModuleRow(_ modules: [ControlDeckStatusModuleItem]) -> some View {
    HStack(spacing: Spacing.xs) {
      ForEach(Array(modules.enumerated()), id: \.element.id) { index, module in
        if index > 0 {
          Text("\u{00B7}")
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
        }

        moduleView(module)
      }
    }
  }

  private var controlModules: [ControlDeckStatusModuleItem] {
    modules.filter { isControlModule($0) }
  }

  private var metadataModules: [ControlDeckStatusModuleItem] {
    modules.filter { !isControlModule($0) }
  }

  private func pickerOptions(for module: ControlDeckStatusModuleItem) -> [ControlDeckStatusModuleItem.Option] {
    switch module.interaction {
      case let .picker(options):
        options
      case .readOnly, .actions:
        []
    }
  }

  private func codexCollaborationModes(for module: ControlDeckStatusModuleItem) -> [CodexCollaborationMode] {
    let modes = pickerOptions(for: module).compactMap { option in
      CodexCollaborationMode.from(rawValue: option.value)
    }
    return modes.isEmpty ? CodexCollaborationMode.allCases : modes
  }

  private func permissionModeValue(
    _ mode: ClaudePermissionMode,
    for module: ControlDeckStatusModuleItem
  ) -> String {
    selectedOptionValue(for: module, fallback: mode.rawValue) {
      ClaudePermissionMode(fromServer: $0.value) == mode
    }
  }

  private func approvalModeValue(
    _ mode: CodexApprovalMode,
    for module: ControlDeckStatusModuleItem
  ) -> String {
    selectedOptionValue(for: module, fallback: mode.rawValue) {
      CodexApprovalMode.from(rawValue: $0.value) == mode
    }
  }

  private func collaborationModeValue(
    _ mode: CodexCollaborationMode,
    for module: ControlDeckStatusModuleItem
  ) -> String {
    selectedOptionValue(for: module, fallback: mode.rawValue) {
      CodexCollaborationMode.from(rawValue: $0.value) == mode
    }
  }

  private func effortValue(
    _ level: EffortLevel,
    for module: ControlDeckStatusModuleItem
  ) -> String {
    selectedOptionValue(for: module, fallback: level.rawValue) {
      EffortLevel.fromControlDeckValue($0.value) == level
    }
  }

  private func selectedOptionValue(
    for module: ControlDeckStatusModuleItem,
    fallback: String,
    where matches: (ControlDeckStatusModuleItem.Option) -> Bool
  ) -> String {
    let options = pickerOptions(for: module)
    if let match = options.first(where: matches) {
      return match.value
    }
    return fallback
  }

  private func autoReviewValue(for level: AutonomyLevel) -> String {
    switch level {
      case .locked: "locked"
      case .guarded: "guarded"
      case .autonomous: "autonomous"
      case .open: "open"
      case .fullAuto: "full_auto"
      case .unrestricted: "unrestricted"
    }
  }

  private func moduleTextColor(_ module: ControlDeckStatusModuleItem, interactive: Bool) -> Color {
    if module.id == .tokens {
      return tintColor(module.tintName)
    }
    return interactive ? Color.textPrimary : Color.textSecondary
  }

  private func tintColor(_ name: String) -> Color {
    switch name {
      case "accent": .accent
      case "feedbackPositive": .feedbackPositive
      case "feedbackWarning": .feedbackWarning
      case "feedbackCaution": .feedbackCaution
      case "statusPermission": .statusPermission
      case "statusEnded": .statusEnded
      case "gitBranch": .gitBranch
      case "textTertiary": .textTertiary
      case "textSecondary": .textSecondary
      case "textQuaternary": .textQuaternary
      case "autonomyLocked": .autonomyLocked
      case "autonomyGuarded": .autonomyGuarded
      case "autonomyAutonomous": .autonomyAutonomous
      case "autonomyOpen": .autonomyOpen
      case "autonomyFullAuto": .autonomyFullAuto
      case "autonomyUnrestricted": .autonomyUnrestricted
      default: .textTertiary
    }
  }
}
