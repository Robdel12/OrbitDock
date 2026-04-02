import Foundation

enum ControlDeckPresentationBuilder {
  static func build(
    snapshot: ControlDeckSnapshot,
    isLoading: Bool,
    hasPendingApproval: Bool = false,
    availableModels: [String] = []
  ) -> ControlDeckPresentation {
    let state = snapshot.state
    let mode = resolveMode(state: state, hasPendingApproval: hasPendingApproval)

    return ControlDeckPresentation(
      mode: mode,
      controlModeLabel: controlModeLabel(state.controlMode),
      lifecycleLabel: lifecycleLabel(state.lifecycle),
      lifecycleTint: lifecycleTint(state.lifecycle),
      acceptsUserInput: state.acceptsUserInput,
      canResume: canResume(state: state),
      supportsImages: snapshot.capabilities.supportsImages,
      headerSubtitle: headerSubtitle(state: state, isLoading: isLoading),
      statusModules: buildStatusModules(
        state: state,
        capabilities: snapshot.capabilities,
        preferences: snapshot.preferences,
        tokenStatus: snapshot.tokenStatus,
        availableModels: availableModels
      ),
      placeholder: placeholder(for: mode),
      sendTint: sendTint(for: mode)
    )
  }

  // MARK: - Mode Resolution

  private static func resolveMode(state: ControlDeckSessionState, hasPendingApproval: Bool = false) -> ControlDeckMode {
    if state.lifecycle == .ended { return .disabled }
    if hasPendingApproval { return .approval }
    if state.steerable, !state.acceptsUserInput { return .steer }
    if state.acceptsUserInput { return .compose }
    return .disabled
  }

  private static func placeholder(for mode: ControlDeckMode) -> String {
    switch mode {
      case .compose: "Signal the deck\u{2026}"
      case .steer: "Adjust trajectory…"
      case .approval: "Approve orbiting move…"
      case .disabled: "Session ended"
    }
  }

  private static func canResume(state: ControlDeckSessionState) -> Bool {
    guard state.controlMode == .direct else { return false }
    if state.lifecycle == .resumable || state.lifecycle == .ended {
      return true
    }
    // Harden transient state after resume: lifecycle can report open before
    // acceptsUserInput flips, and we should keep the resume affordance visible.
    return state.lifecycle == .open && !state.acceptsUserInput
  }

  private static func sendTint(for mode: ControlDeckMode) -> String {
    switch mode {
      case .compose: "accent"
      case .steer: "feedbackWarning"
      case .approval: "accent"
      case .disabled: "textQuaternary"
    }
  }

  // MARK: - Status Modules

  static func buildStatusModules(
    state: ControlDeckSessionState,
    capabilities: ControlDeckCapabilities,
    preferences: ControlDeckPreferences,
    tokenStatus: ControlDeckTokenStatus,
    availableModels: [String] = []
  ) -> [ControlDeckStatusModuleItem] {
    let visibleSet = Set(
      preferences.modules.filter(\.visible).map(\.module)
    )
    let available = Set(capabilities.availableStatusModules)

    // Connection is an app-level concern, not a session concern — filter it out
    return capabilities.availableStatusModules.compactMap { module in
      guard module != .connection,
            available.contains(module),
            visibleSet.contains(module) else { return nil }
      return moduleItem(
        module,
        state: state,
        capabilities: capabilities,
        tokenStatus: tokenStatus,
        availableModels: availableModels
      )
    }
  }

  // MARK: - Private Helpers

  private static func controlModeLabel(_ mode: ControlDeckControlMode) -> String {
    switch mode {
      case .direct: "Direct"
      case .passive: "Passive"
    }
  }

  private static func lifecycleLabel(_ lifecycle: ControlDeckLifecycle) -> String {
    switch lifecycle {
      case .open: "Open"
      case .resumable: "Resumable"
      case .ended: "Ended"
    }
  }

  private static func lifecycleTint(_ lifecycle: ControlDeckLifecycle) -> String {
    switch lifecycle {
      case .open: "feedbackPositive"
      case .resumable: "feedbackWarning"
      case .ended: "statusEnded"
    }
  }

  private static func headerSubtitle(state: ControlDeckSessionState, isLoading: Bool) -> String {
    if isLoading { return "Syncing\u{2026}" }
    switch state.lifecycle {
      case .open: return "Ready"
      case .resumable: return "Session paused"
      case .ended: return "Session ended"
    }
  }

  private static func moduleItem(
    _ module: ControlDeckStatusModule,
    state: ControlDeckSessionState,
    capabilities: ControlDeckCapabilities,
    tokenStatus: ControlDeckTokenStatus,
    availableModels: [String] = []
  ) -> ControlDeckStatusModuleItem? {
    let folder = (state.currentCwd ?? state.projectPath).split(separator: "/").last.map(String.init) ?? "\u{2014}"
    let effortOptions = ["low", "medium", "high"]

    switch module {
      case .connection:
        return ControlDeckStatusModuleItem(
          id: .connection,
          label: "Connected",
          icon: "wifi",
          tintName: "feedbackPositive",
          selectedValue: nil,
          reviewerValue: nil,
          interaction: .readOnly
        )
      case .autonomy:
        return ControlDeckStatusModuleItem(
          id: .autonomy,
          label: optionLabel(
            for: state.config.permissionMode,
            options: capabilities.permissionModeOptions,
            fallback: "Default"
          ),
          icon: "shield",
          tintName: "accent",
          selectedValue: state.config.permissionMode,
          reviewerValue: nil,
          interaction: .picker(options: pickerOptions(from: capabilities.permissionModeOptions))
        )
      case .approvalMode:
        return ControlDeckStatusModuleItem(
          id: .approvalMode,
          label: optionLabel(
            for: state.config.approvalPolicy,
            options: capabilities.approvalModeOptions,
            fallback: "Default"
          ),
          icon: "checkmark.shield.fill",
          tintName: "accent",
          selectedValue: state.config.approvalPolicy,
          reviewerValue: state.config.approvalsReviewer?.rawValue,
          interaction: .picker(options: pickerOptions(from: capabilities.approvalModeOptions))
        )
      case .collaborationMode:
        return ControlDeckStatusModuleItem(
          id: .collaborationMode,
          label: optionLabel(
            for: state.config.collaborationMode,
            options: capabilities.collaborationModeOptions,
            fallback: "Default"
          ),
          icon: "person.2",
          tintName: "accent",
          selectedValue: state.config.collaborationMode,
          reviewerValue: nil,
          interaction: .picker(options: pickerOptions(from: capabilities.collaborationModeOptions))
        )
      case .autoReview:
        let currentAutoReview = autoReviewOption(
          approvalPolicy: state.config.approvalPolicy,
          sandboxMode: state.config.sandboxMode,
          options: capabilities.autoReviewOptions
        )
        return ControlDeckStatusModuleItem(
          id: .autoReview,
          label: currentAutoReview?.label ?? "Custom",
          icon: "eye",
          tintName: autoReviewTintName(optionValue: currentAutoReview?.value),
          selectedValue: currentAutoReview?.value,
          reviewerValue: nil,
          interaction: .picker(options: autoReviewPickerOptions(from: capabilities.autoReviewOptions))
        )
      case .tokens:
        return ControlDeckStatusModuleItem(
          id: .tokens,
          label: tokenStatus.label,
          icon: "memorychip",
          tintName: tokenTintName(tokenStatus.tone),
          selectedValue: nil,
          reviewerValue: nil,
          interaction: .readOnly
        )
      case .model:
        let canPick = capabilities.allowPerTurnModelOverride && !availableModels.isEmpty
        return ControlDeckStatusModuleItem(
          id: .model,
          label: shortModelLabel(state.config.model),
          icon: "cpu",
          tintName: "textTertiary",
          selectedValue: state.config.model,
          reviewerValue: nil,
          interaction: canPick ? .picker(options: availableModels.map { .init(value: $0, label: $0) }) : .readOnly
        )
      case .effort:
        return ControlDeckStatusModuleItem(
          id: .effort,
          label: state.config.effort?.capitalized ?? "Default",
          icon: "gauge.medium",
          tintName: "textTertiary",
          selectedValue: state.config.effort,
          reviewerValue: nil,
          interaction: .picker(options: effortOptions.map { .init(value: $0, label: $0.capitalized) })
        )
      case .branch:
        // Hide branch module when no git data — showing "—" with the branch icon
        // looks like a signal strength indicator at small sizes
        guard let branchName = state.gitBranch, !branchName.isEmpty else {
          return nil
        }
        return ControlDeckStatusModuleItem(
          id: .branch,
          label: branchName,
          icon: "arrow.triangle.branch",
          tintName: "gitBranch",
          selectedValue: nil,
          reviewerValue: nil,
          interaction: .readOnly
        )
      case .cwd:
        return ControlDeckStatusModuleItem(
          id: .cwd,
          label: folder,
          icon: "folder",
          tintName: "textTertiary",
          selectedValue: nil,
          reviewerValue: nil,
          interaction: .readOnly
        )
      case .attachments:
        return ControlDeckStatusModuleItem(
          id: .attachments,
          label: "Attachments",
          icon: "paperclip",
          tintName: "textTertiary",
          selectedValue: nil,
          reviewerValue: nil,
          interaction: .readOnly
        )
    }
  }

  // MARK: - Model Display

  private static func shortModelLabel(_ model: String?) -> String {
    guard let model else { return "Default" }
    // Strip common prefixes for compact display
    let shortened = model
      .replacingOccurrences(of: "claude-", with: "")
      .replacingOccurrences(of: "-20251001", with: "")
    return shortened
  }

  private static func optionLabel(
    for value: String?,
    options: [ControlDeckPickerOption],
    fallback: String
  ) -> String {
    guard let value else { return fallback }
    return options.first(where: { $0.value.caseInsensitiveCompare(value) == .orderedSame })?.label ?? value
  }

  private static func pickerOptions(
    from options: [ControlDeckPickerOption]
  ) -> [ControlDeckStatusModuleItem.Option] {
    options.map { option in
      ControlDeckStatusModuleItem.Option(value: option.value, label: option.label)
    }
  }

  private static func autoReviewPickerOptions(
    from options: [ControlDeckAutoReviewOption]
  ) -> [ControlDeckStatusModuleItem.Option] {
    options.map { option in
      ControlDeckStatusModuleItem.Option(value: option.value, label: option.label)
    }
  }

  private static func autoReviewOption(
    approvalPolicy: String?,
    sandboxMode: String?,
    options: [ControlDeckAutoReviewOption]
  ) -> ControlDeckAutoReviewOption? {
    options.first { option in
      option.approvalPolicy == approvalPolicy && option.sandboxMode == sandboxMode
    }
  }

  private static func autoReviewTintName(optionValue: String?) -> String {
    switch optionValue {
      case "locked": "autonomyLocked"
      case "guarded": "autonomyGuarded"
      case "autonomous": "autonomyAutonomous"
      case "open": "autonomyOpen"
      case "full_auto": "autonomyFullAuto"
      case "unrestricted": "autonomyUnrestricted"
      default: "accent"
    }
  }

  private static func tokenTintName(_ tone: ControlDeckTokenStatus.Tone) -> String {
    switch tone {
      case .muted: "textQuaternary"
      case .normal: "textTertiary"
      case .caution: "feedbackCaution"
      case .critical: "statusPermission"
    }
  }
}
