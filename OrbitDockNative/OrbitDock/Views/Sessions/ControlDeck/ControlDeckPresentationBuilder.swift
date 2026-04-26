import Foundation

enum ControlDeckPresentationBuilder {
  static func build(
    snapshot: ControlDeckSnapshot,
    isLoading: Bool,
    availableModels: [String] = []
  ) -> ControlDeckPresentation {
    let state = snapshot.state
    let activityStatus = resolveActivityStatus(snapshot: snapshot)
    let mode = resolveMode(state: state, hasPendingApproval: snapshot.pendingApproval != nil)

    return ControlDeckPresentation(
      mode: mode,
      activityStatus: activityStatus,
      controlModeLabel: controlModeLabel(state.controlMode),
      lifecycleLabel: lifecycleLabel(state.lifecycle),
      lifecycleTint: lifecycleTint(state.lifecycle),
      acceptsUserInput: state.acceptsUserInput,
      canInterrupt: state.canInterrupt && state.connectorAttached,
      canResume: canResume(state: state),
      supportsImages: snapshot.capabilities.supportsImages,
      headerSubtitle: headerSubtitle(state: state, activityStatus: activityStatus, isLoading: isLoading),
      statusModules: buildStatusModules(
        state: state,
        capabilities: snapshot.capabilities,
        preferences: snapshot.preferences,
        tokenStatus: snapshot.tokenStatus,
        turnControls: snapshot.turnControls,
        availableModels: availableModels
      ),
      turnControls: snapshot.turnControls,
      placeholder: placeholder(for: mode),
      sendTint: sendTint(for: mode)
    )
  }

  // MARK: - Mode Resolution

  private static func resolveMode(state: ControlDeckSessionState, hasPendingApproval: Bool = false) -> ControlDeckMode {
    if state.lifecycle == .ended { return .disabled }
    // Only show approval mode if connector is attached — otherwise user needs to resume first
    if hasPendingApproval, state.connectorAttached { return .approval }
    if state.steerable, state.connectorAttached { return .steer }
    if state.acceptsUserInput, state.connectorAttached { return .compose }
    return .disabled
  }

  private static func resolveActivityStatus(snapshot: ControlDeckSnapshot) -> ControlDeckActivityStatus {
    let state = snapshot.state
    if state.lifecycle == .ended {
      return .ended
    }

    if let pendingApproval = snapshot.pendingApproval, state.connectorAttached {
      switch pendingApproval.kind {
        case .question:
          return .question
        case .tool, .patch, .permission:
          return .permission
      }
    }

    switch state.workStatus {
      case .working:
        return .working
      case .permission:
        return .permission
      case .question:
        return .question
      case .waiting, .reply:
        return .ready
      case .ended:
        return .ended
    }
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
    // Keep resume visible for detached-open sessions that have not yet restored
    // connector ownership, but do not show resume for normal attached working
    // sessions that are already actively processing.
    return state.lifecycle == .open && !state.connectorAttached
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
    turnControls: ControlDeckTurnControls? = nil,
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
        turnControls: turnControls,
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

  private static func headerSubtitle(
    state: ControlDeckSessionState,
    activityStatus: ControlDeckActivityStatus,
    isLoading: Bool
  ) -> String {
    if isLoading { return "Syncing\u{2026}" }
    switch state.lifecycle {
      case .resumable:
        return "Session paused"
      case .ended:
        return "Session ended"
      case .open:
        switch activityStatus {
          case .working:
            return "Working"
          case .permission:
            return "Awaiting approval"
          case .question:
            return "Awaiting answer"
          case .ready:
            return "Ready"
          case .ended:
            return "Session ended"
        }
    }
  }

  private static func moduleItem(
    _ module: ControlDeckStatusModule,
    state: ControlDeckSessionState,
    capabilities: ControlDeckCapabilities,
    tokenStatus: ControlDeckTokenStatus,
    turnControls: ControlDeckTurnControls? = nil,
    availableModels: [String] = []
  ) -> ControlDeckStatusModuleItem? {
    let folder = (state.currentCwd ?? state.projectPath).split(separator: "/").last.map(String.init) ?? "\u{2014}"
    let effortOptions = capabilities.effortOptions.isEmpty
      ? EffortLevel.concreteCases.map { ControlDeckPickerOption(value: $0.rawValue, label: $0.displayName) }
      : capabilities.effortOptions

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
          sandboxPolicyDetails: ServerCodexSandboxPolicy.resolved(
            details: state.config.sandboxPolicyDetails
          ),
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
          approvalPolicyDetails: state.config.approvalPolicyDetails,
          sandboxMode: state.config.sandboxMode,
          sandboxPolicyDetails: state.config.sandboxPolicyDetails,
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
          interaction: .picker(options: pickerOptions(from: effortOptions))
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
      case .turnControls:
        guard let controls = turnControls, controls.hasAnySupported else {
          return nil
        }
        return buildTurnControlsModule(controls)
    }
  }

  private static func buildTurnControlsModule(
    _ controls: ControlDeckTurnControls
  ) -> ControlDeckStatusModuleItem {
    var actions: [ControlDeckStatusModuleItem.ActionItem] = []

    if controls.undoLastTurn.supported {
      actions.append(.init(
        action: "undo",
        label: "Undo Last Turn",
        icon: "arrow.uturn.backward",
        isEnabled: controls.undoLastTurn.available
      ))
    }

    if controls.compactContext.supported {
      actions.append(.init(
        action: "compact",
        label: "Compact Context",
        icon: "arrow.down.right.and.arrow.up.left",
        isEnabled: controls.compactContext.available
      ))
    }

    if controls.rollbackTurns.supported {
      actions.append(contentsOf: rollbackActionItems(controls))
    }

    return ControlDeckStatusModuleItem(
      id: .turnControls,
      label: "Turn",
      icon: "arrow.uturn.backward.circle",
      tintName: "textSecondary",
      selectedValue: nil,
      reviewerValue: nil,
      interaction: .actions(items: actions)
    )
  }

  private static func rollbackActionItems(
    _ controls: ControlDeckTurnControls
  ) -> [ControlDeckStatusModuleItem.ActionItem] {
    let maxTurns = max(1, controls.maxRollbackTurns)
    let counts: [Int]
    if maxTurns <= 3 {
      counts = Array(1...maxTurns)
    } else {
      counts = [1, 2, 5, maxTurns]
        .filter { $0 <= maxTurns }
        .reduce(into: [Int]()) { ordered, count in
          if !ordered.contains(count) {
            ordered.append(count)
          }
        }
    }

    return counts.map { count in
      ControlDeckStatusModuleItem.ActionItem(
        action: "rollback:\(count)",
        label: rollbackLabel(for: count),
        icon: "arrow.counterclockwise",
        isEnabled: controls.rollbackTurns.available,
        isDestructive: true
      )
    }
  }

  private static func rollbackLabel(for count: Int) -> String {
    if count == 1 {
      return "Rollback 1 Turn"
    }
    return "Rollback \(count) Turns"
  }

  // MARK: - Model Display

  private static func shortModelLabel(_ model: String?) -> String {
    ModelCatalog.describe(model)?.displayName ?? "Default"
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
    approvalPolicyDetails: ServerCodexApprovalPolicy?,
    sandboxMode: String?,
    sandboxPolicyDetails: ServerCodexSandboxPolicy?,
    options: [ControlDeckAutoReviewOption]
  ) -> ControlDeckAutoReviewOption? {
    let resolvedApproval = ServerCodexApprovalPolicy.resolved(details: approvalPolicyDetails)
    let resolvedSandbox = ServerCodexSandboxPolicy.resolved(details: sandboxPolicyDetails)

    return options.first { option in
      let optionApproval = ServerCodexApprovalPolicy.resolved(
        details: option.approvalPolicyDetails
      )
      let optionSandbox = ServerCodexSandboxPolicy.resolved(
        details: option.sandboxPolicyDetails
      )
      return optionApproval == resolvedApproval && optionSandbox == resolvedSandbox
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
