import SwiftUI

struct ControlDeckStatusBar: View {
  let modules: [ControlDeckStatusModuleItem]
  var onModuleAction: ((ControlDeckStatusModule, String) -> Void)?
  var onApprovalReviewerAction: ((ServerCodexApprovalsReviewer) -> Void)?

  // Action buttons
  var supportsImages: Bool = false
  var canPasteImage: Bool = false
  var canSubmit: Bool = false
  var canResume: Bool = false
  var isSubmitting: Bool = false
  var sendTint: String = "accent"
  var onAddImage: (() -> Void)?
  var onPasteImage: (() -> Void)?
  var onSubmit: (() -> Void)?
  var onResume: (() -> Void)?
  var isDictating: Bool = false
  var isSessionWorking: Bool = false
  var onDictation: (() -> Void)?
  var onInterrupt: (() -> Void)?

  // Approval mode
  var approvalMode: ApprovalClusterMode = .none
  var onApprove: (() -> Void)?
  var onApproveForSession: (() -> Void)?
  var onDeny: (() -> Void)?

  enum ApprovalClusterMode: Equatable {
    case none
    case tool  // Approve / Deny for tool execution
    case patch // Approve / Deny for file edits
    case permission // Grant / Deny for permissions
  }

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var isCompactIOS: Bool {
    #if os(iOS)
      horizontalSizeClass == .compact
    #else
      false
    #endif
  }

  private var minimumBarHeight: CGFloat {
    #if os(iOS)
      isCompactIOS ? 38 : 42
    #else
      28
    #endif
  }

  private var actionButtonSize: CGFloat {
    #if os(iOS)
      isCompactIOS ? 32 : 34
    #else
      26
    #endif
  }

  private var sendButtonSize: CGFloat {
    #if os(iOS)
      isCompactIOS ? 34 : 36
    #else
      28
    #endif
  }

  var body: some View {
    HStack(spacing: isCompactIOS ? Spacing.xs : Spacing.sm_) {
      // Action buttons (left edge)
      actionButtons

      // Scrollable status modules (fills middle)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: isCompactIOS ? Spacing.xs : Spacing.sm) {
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
    HStack(spacing: isCompactIOS ? Spacing.xs : Spacing.xxs) {
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

  @ViewBuilder
  private var sendCluster: some View {
    if approvalMode != .none {
      approvalCluster
    } else {
      HStack(spacing: isCompactIOS ? Spacing.xs : Spacing.sm_) {
        sendButton
      }
    }
  }

  // MARK: - Approval Cluster

  private var approvalCluster: some View {
    HStack(spacing: Spacing.sm_) {
      // Deny button
      Button(action: { onDeny?() }) {
        Text("Deny")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textSecondary)
          .padding(.horizontal, Spacing.sm)
          .frame(height: approvalButtonHeight)
          .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
      }
      .buttonStyle(.plain)

      // Approve button with dropdown
      HStack(spacing: 0) {
        Button(action: { onApprove?() }) {
          HStack(spacing: Spacing.xxs) {
            Image(systemName: "checkmark")
              .font(.system(size: 9, weight: .bold))
            Text(approvalActionLabel)
              .font(.system(size: TypeScale.caption, weight: .semibold))
          }
          .foregroundStyle(Color.backgroundPrimary)
          .padding(.horizontal, Spacing.sm)
          .frame(height: approvalButtonHeight)
        }
        .buttonStyle(.plain)

        Menu {
          Button("\(approvalActionLabel) for Session") { onApproveForSession?() }
        } label: {
          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.backgroundPrimary.opacity(0.7))
            .frame(width: 24, height: approvalButtonHeight)
        }
        .buttonStyle(.plain)
      }
      .background(Color.feedbackPositive, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
  }

  private var approvalButtonHeight: CGFloat {
    #if os(iOS)
      isCompactIOS ? 32 : 34
    #else
      26
    #endif
  }

  private var approvalActionLabel: String {
    switch approvalMode {
      case .permission: "Grant"
      default: "Approve"
    }
  }

  @ViewBuilder
  private var sendButton: some View {
    if isSessionWorking, !canSubmit {
      Button(action: { onInterrupt?() }) {
        Image(systemName: "stop.fill")
          .font(.system(size: TypeScale.caption, weight: .bold))
          .frame(width: sendButtonSize, height: sendButtonSize)
          .foregroundStyle(Color.statusError)
          .background(Color.statusError.opacity(OpacityTier.light), in: Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Stop")
    } else if canResume {
      Button(action: { onResume?() }) {
        Image(systemName: "play.fill")
          .font(.system(size: TypeScale.caption, weight: .bold))
          .frame(width: sendButtonSize, height: sendButtonSize)
          .foregroundStyle(Color.feedbackWarning)
          .background(Color.feedbackWarning.opacity(OpacityTier.light), in: Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Resume")
    } else {
      Button(action: { onSubmit?() }) {
        Group {
          if isSubmitting {
            ProgressView()
              .controlSize(.mini)
              .tint(.white)
          } else {
            Image(systemName: "arrow.up")
              .font(.system(size: TypeScale.caption, weight: .bold))
              .foregroundStyle(canSubmit ? Color.backgroundPrimary : Color.textQuaternary)
          }
        }
        .frame(width: sendButtonSize, height: sendButtonSize)
        .background(canSubmit ? resolvedSendTint : Color.backgroundTertiary, in: Circle())
      }
      .buttonStyle(.plain)
      .disabled(!canSubmit || isSubmitting)
      .accessibilityLabel("Send")
    }
  }

  private var resolvedSendTint: Color {
    switch sendTint {
      case "accent": .accent
      case "feedbackWarning": .feedbackWarning
      case "feedbackCaution": .feedbackCaution
      case "feedbackPositive": .feedbackPositive
      default: .accent
    }
  }

  // MARK: - Module View

  @ViewBuilder
  private func moduleView(_ module: ControlDeckStatusModuleItem) -> some View {
    if let specialized = specializedControlView(module) {
      specialized
    } else {
      genericModuleView(module)
    }
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
        .font(.system(size: isCompactIOS ? TypeScale.caption : TypeScale.subhead, weight: .semibold))
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
    HStack(spacing: isCompactIOS ? Spacing.xs : Spacing.xs) {
      ForEach(modules) { module in
        moduleView(module)
      }
    }
  }

  private func metadataModuleRow(_ modules: [ControlDeckStatusModuleItem]) -> some View {
    HStack(spacing: isCompactIOS ? Spacing.xs : Spacing.xs) {
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
    modules.filter { module in
      switch module.id {
        case .autonomy, .approvalMode, .collaborationMode, .autoReview, .effort:
          true
        default:
          false
      }
    }
  }

  private var metadataModules: [ControlDeckStatusModuleItem] {
    modules.filter { module in
      switch module.id {
        case .autonomy, .approvalMode, .collaborationMode, .autoReview, .effort:
          false
        default:
          true
      }
    }
  }

  private func specializedControlView(_ module: ControlDeckStatusModuleItem) -> AnyView? {
    switch module.id {
      case .autonomy:
        return AnyView(
          ClaudePermissionPill(
            currentMode: ClaudePermissionMode(fromServer: module.selectedValue),
            size: .statusBar,
            onUpdate: { mode in
              onModuleAction?(module.id, mode.rawValue)
            }
          )
        )
      case .approvalMode:
        return AnyView(
          CodexApprovalPill(
            currentMode: CodexApprovalMode.from(rawValue: module.selectedValue),
            currentReviewer: CodexApprovalsReviewer.from(rawValue: module.reviewerValue),
            supportedModes: CodexApprovalMode.supportedCases(from: pickerOptions(for: module)),
            size: .statusBar,
            onUpdate: { mode in
              onModuleAction?(module.id, mode.rawValue)
            },
            onReviewerUpdate: { reviewer in
              onApprovalReviewerAction?(ServerCodexApprovalsReviewer(rawValue: reviewer.rawValue) ?? .user)
            }
          )
        )
      case .collaborationMode:
        return AnyView(
          CodexModePill(
            currentMode: CodexCollaborationMode.from(rawValue: module.selectedValue),
            supportedModes: codexCollaborationModes(for: module),
            size: .statusBar,
            onUpdate: { mode in
              onModuleAction?(module.id, mode.rawValue)
            }
          )
        )
      case .autoReview:
        guard let level = AutonomyLevel.fromAutoReviewValue(module.selectedValue) else {
          return nil
        }
        return AnyView(
          CodexAutoReviewPill(
            currentLevel: level,
            supportedLevels: AutonomyLevel.supportedAutoReviewCases(from: pickerOptions(for: module)),
            size: .statusBar,
            onUpdate: { level in
              onModuleAction?(module.id, autoReviewValue(for: level))
            }
          )
        )
      case .effort:
        return AnyView(
          EffortPill(
            currentLevel: EffortLevel.fromControlDeckValue(module.selectedValue),
            supportedLevels: EffortLevel.supportedControlDeckCases(from: pickerOptions(for: module)),
            size: .statusBar,
            onUpdate: { level in
              onModuleAction?(module.id, level.rawValue)
            }
          )
        )
      default:
        return nil
    }
  }

  private func pickerOptions(for module: ControlDeckStatusModuleItem) -> [ControlDeckStatusModuleItem.Option] {
    switch module.interaction {
      case let .picker(options):
        options
      case .readOnly:
        []
    }
  }

  private func codexCollaborationModes(for module: ControlDeckStatusModuleItem) -> [CodexCollaborationMode] {
    let modes = pickerOptions(for: module).compactMap { option in
      CodexCollaborationMode(rawValue: option.value)
    }
    return modes.isEmpty ? CodexCollaborationMode.allCases : modes
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
