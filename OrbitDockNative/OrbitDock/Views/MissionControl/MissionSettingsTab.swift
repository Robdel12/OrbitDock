import SwiftUI

struct MissionSettingsTab: View {
  let settings: MissionSettings?
  let repoRoot: String
  let missionId: String
  let http: ServerHTTPClient?
  let isCompact: Bool
  let onUpdated: () async -> Void

  @State private var isSaving = false
  @State private var saveError: String?
  @State private var showSaveConfirmation = false
  @State private var confirmationTask: Task<Void, Never>?

  // Trigger
  @State private var triggerKind = "polling"
  @State private var pollInterval: UInt64 = 60
  @State private var editLabels = ""
  @State private var editStates = ""
  @State private var editProject = ""
  @State private var editTeam = ""

  // Provider
  @State private var providerStrategy = "single"
  @State private var primaryProvider = "claude"
  @State private var secondaryProvider = ""
  @State private var maxConcurrent: UInt32 = 3
  @State private var maxConcurrentPrimary: UInt32 = 2

  // Agent — Claude (default to mission-safe: acceptEdits)
  @State private var claudeModel = ""
  @State private var claudeEffort: EffortLevel = .default
  @State private var claudePermission: ClaudePermissionMode = .acceptEdits
  @State private var claudeAllowedTools = ""
  @State private var claudeDisallowedTools = ""
  @State private var claudeAllowBypass = false

  // Agent — Codex (default to mission-safe: autonomous)
  @State private var codexModel = ""
  @State private var codexEffort: EffortLevel = .default
  @State private var codexAutonomy: AutonomyLevel = .autonomous
  @State private var codexMultiAgent = false
  @State private var codexCollaboration: CodexCollaborationMode = .default
  @State private var codexDevInstructions = ""

  // Orchestration
  @State private var maxRetries: UInt32 = 3
  @State private var stallTimeout: UInt64 = 600
  @State private var baseBranch = "main"
  @State private var worktreeRootDir = ""
  @State private var stateOnDispatch = "In Progress"
  @State private var stateOnComplete = "In Review"
  @State private var showFullTemplate = false

  // Tracker
  @State private var trackerKeyConfigured = false
  @State private var trackerKeySource: String?
  @State private var newApiKey = ""
  @State private var isSavingKey = false
  @State private var keyError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: isCompact ? Spacing.lg : Spacing.xl) {
      MissionTrackerSection(
        trackerKeyConfigured: $trackerKeyConfigured,
        trackerKeySource: $trackerKeySource,
        newApiKey: $newApiKey,
        isSavingKey: $isSavingKey,
        keyError: $keyError,
        http: http,
        onUpdated: onUpdated
      )

      // Source control context
      HStack(spacing: Spacing.sm_) {
        Image(systemName: "doc.text")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
        Text(isCompact
          ? "Saved to MISSION.md in your repo."
          : "Settings below are saved to MISSION.md — committed to source control and shared with your team.")
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(isCompact ? Spacing.sm : Spacing.md)
      .background(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .fill(Color.backgroundTertiary.opacity(0.5))
      )

      if isCompact {
        providerSection
        agentSection
        triggerSection
        orchestrationSection
      } else {
        HStack(alignment: .top, spacing: Spacing.sm) {
          providerSection
          agentSection
        }

        HStack(alignment: .top, spacing: Spacing.sm) {
          triggerSection
          orchestrationSection
        }
      }

      MissionPromptSection(
        promptTemplate: settings?.promptTemplate ?? "",
        repoRoot: repoRoot,
        isCompact: isCompact,
        showFullTemplate: $showFullTemplate
      )

      saveFooter
    }
    .onAppear {
      populateFromSettings()
      Task { await fetchTrackerKeyStatus() }
    }
    .onChange(of: settings) { _, _ in populateFromSettings() }
  }

  // MARK: - Composed Sections

  private var providerSection: some View {
    MissionProviderSection(
      providerStrategy: $providerStrategy,
      primaryProvider: $primaryProvider,
      secondaryProvider: $secondaryProvider,
      maxConcurrent: $maxConcurrent,
      maxConcurrentPrimary: $maxConcurrentPrimary,
      isCompact: isCompact
    )
  }

  private var triggerSection: some View {
    MissionTriggerSection(
      triggerKind: $triggerKind,
      pollInterval: $pollInterval,
      editLabels: $editLabels,
      editStates: $editStates,
      editProject: $editProject,
      editTeam: $editTeam,
      isCompact: isCompact
    )
  }

  private var orchestrationSection: some View {
    MissionOrchestrationSection(
      maxRetries: $maxRetries,
      stallTimeout: $stallTimeout,
      baseBranch: $baseBranch,
      worktreeRootDir: $worktreeRootDir,
      stateOnDispatch: $stateOnDispatch,
      stateOnComplete: $stateOnComplete,
      repoRoot: repoRoot,
      isCompact: isCompact
    )
  }

  // MARK: - Agent Section

  private var isClaudeActive: Bool {
    primaryProvider == "claude" || providerStrategy != "single"
  }

  private var isCodexActive: Bool {
    primaryProvider == "codex" || providerStrategy != "single"
  }

  private var agentSection: some View {
    missionInstrumentPanel(
      title: "Agent",
      icon: "gearshape",
      description: "Model, effort, and permissions for dispatched agents",
      isCompact: isCompact
    ) {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        HStack(spacing: Spacing.sm_) {
          Image(systemName: "bolt.circle.fill")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.feedbackCaution)
          Text("Mission agents run autonomously — only headless-safe permission modes are available.")
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }

        MissionClaudeAgentSection(
          claudeModel: $claudeModel,
          claudeEffort: $claudeEffort,
          claudePermission: $claudePermission,
          claudeAllowedTools: $claudeAllowedTools,
          claudeDisallowedTools: $claudeDisallowedTools,
          claudeAllowBypass: $claudeAllowBypass,
          isCompact: isCompact
        )
        .opacity(isClaudeActive ? 1 : 0.4)
        .allowsHitTesting(isClaudeActive)
        .overlay(alignment: .topTrailing) {
          if !isClaudeActive {
            inactiveProviderBadge
          }
        }

        HStack(spacing: Spacing.md) {
          Rectangle()
            .fill(Color.surfaceBorder.opacity(OpacityTier.medium))
            .frame(height: 1)
        }
        .padding(.vertical, Spacing.xs)

        MissionCodexAgentSection(
          codexModel: $codexModel,
          codexEffort: $codexEffort,
          codexAutonomy: $codexAutonomy,
          codexMultiAgent: $codexMultiAgent,
          codexCollaboration: $codexCollaboration,
          codexDevInstructions: $codexDevInstructions,
          isCompact: isCompact
        )
        .opacity(isCodexActive ? 1 : 0.4)
        .allowsHitTesting(isCodexActive)
        .overlay(alignment: .topTrailing) {
          if !isCodexActive {
            inactiveProviderBadge
          }
        }
      }
    }
  }

  private var inactiveProviderBadge: some View {
    Text("Not dispatched")
      .font(.system(size: TypeScale.micro, weight: .medium))
      .foregroundStyle(Color.textQuaternary)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xxs)
      .background(Color.backgroundTertiary.opacity(0.6), in: Capsule())
  }

  // MARK: - Save Footer

  private var saveFooter: some View {
    VStack(spacing: Spacing.sm) {
      if let saveError {
        HStack(spacing: Spacing.sm_) {
          Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 10))
            .foregroundStyle(Color.feedbackNegative)
          Text(saveError)
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.feedbackNegative)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      if showSaveConfirmation {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 14))
            .foregroundStyle(Color.feedbackPositive)
          Text("Settings saved to MISSION.md")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.feedbackPositive)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
        .background(
          RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(Color.feedbackPositive.opacity(OpacityTier.light))
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
      }

      HStack(spacing: Spacing.md) {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "doc.text")
            .font(.system(size: 9))
            .foregroundStyle(Color.textQuaternary)
          Text("MISSION.md")
            .font(.system(size: TypeScale.micro, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }

        Spacer()

        Button {
          Task { await saveSettings() }
        } label: {
          HStack(spacing: Spacing.sm_) {
            if isSaving {
              ProgressView()
                .controlSize(.mini)
            } else {
              Image(systemName: "arrow.down.doc")
                .font(.system(size: 11, weight: .semibold))
            }
            Text("Save")
              .font(.system(size: TypeScale.body, weight: .semibold))
          }
          .foregroundStyle(.white)
          .padding(.horizontal, isCompact ? Spacing.lg : Spacing.xl)
          .padding(.vertical, Spacing.md_)
          .frame(maxWidth: isCompact ? .infinity : nil)
          .background(Color.accent, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
      }
    }
  }

  // MARK: - Data

  private func populateFromSettings() {
    guard let s = settings else { return }
    populateFromResponse(s)
  }

  private func populateFromResponse(_ s: MissionSettings) {
    triggerKind = s.trigger.kind
    pollInterval = s.trigger.interval
    editLabels = s.trigger.filters.labels.joined(separator: ", ")
    editStates = s.trigger.filters.states.joined(separator: ", ")
    editProject = s.trigger.filters.project ?? ""
    editTeam = s.trigger.filters.team ?? ""
    providerStrategy = s.provider.strategy
    primaryProvider = s.provider.primary
    secondaryProvider = s.provider.secondary ?? ""
    maxConcurrent = s.provider.maxConcurrent
    maxConcurrentPrimary = s.provider.maxConcurrentPrimary ?? 2

    if let claude = s.agent.claude {
      claudeModel = claude.model ?? ""
      claudeEffort = effortFromString(claude.effort)
      claudePermission = permissionFromString(claude.permissionMode)
      claudeAllowedTools = claude.allowedTools.joined(separator: ", ")
      claudeDisallowedTools = claude.disallowedTools.joined(separator: ", ")
      claudeAllowBypass = claude.allowBypassPermissions ?? false
    } else {
      claudeModel = ""
      claudeEffort = .default
      claudePermission = .acceptEdits
      claudeAllowedTools = ""
      claudeDisallowedTools = ""
      claudeAllowBypass = false
    }

    if let codex = s.agent.codex {
      codexModel = codex.model ?? ""
      codexEffort = effortFromString(codex.effort)
      codexAutonomy = AutonomyLevel.from(
        approvalPolicy: codex.approvalPolicy,
        sandboxMode: codex.sandboxMode
      )
      codexMultiAgent = codex.multiAgent ?? false
      codexCollaboration = CodexCollaborationMode.from(rawValue: codex.collaborationMode)
      codexDevInstructions = codex.developerInstructions ?? ""
    } else {
      codexModel = ""
      codexEffort = .default
      codexAutonomy = .autonomous
      codexMultiAgent = false
      codexCollaboration = .default
      codexDevInstructions = ""
    }

    maxRetries = s.orchestration.maxRetries
    stallTimeout = s.orchestration.stallTimeout
    baseBranch = s.orchestration.baseBranch
    worktreeRootDir = s.orchestration.worktreeRootDir ?? ""
    stateOnDispatch = s.orchestration.stateOnDispatch
    stateOnComplete = s.orchestration.stateOnComplete
  }

  private func effortFromString(_ value: String?) -> EffortLevel {
    guard let value, !value.isEmpty else { return .default }
    return EffortLevel(rawValue: value) ?? .default
  }

  private func permissionFromString(_ value: String?) -> ClaudePermissionMode {
    guard let value, !value.isEmpty else { return .acceptEdits }
    switch value {
      case "plan": return .plan
      case "dontAsk": return .dontAsk
      case "default": return .acceptEdits
      case "acceptEdits": return .acceptEdits
      case "bypassPermissions": return .bypassPermissions
      default: return .acceptEdits
    }
  }

  private func parseCSV(_ text: String) -> [String] {
    text
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  // MARK: - Networking

  private func fetchTrackerKeyStatus() async {
    guard let http else { return }
    struct TrackerKeysResponse: Decodable {
      let linear: TrackerKeyInfo
      struct TrackerKeyInfo: Decodable {
        let configured: Bool
        let source: String?
      }
    }
    do {
      let response: TrackerKeysResponse = try await http.get("/api/server/tracker-keys")
      trackerKeyConfigured = response.linear.configured
      trackerKeySource = response.linear.source
    } catch {
      // Non-critical — status just won't show
    }
  }

  private func saveSettings() async {
    guard let http else { return }

    isSaving = true
    saveError = nil
    showSaveConfirmation = false

    let permissionWire: String? = claudePermission == .default ? nil : {
      switch claudePermission {
        case .plan: "plan"
        case .dontAsk: "dontAsk"
        case .default: "default"
        case .acceptEdits: "acceptEdits"
        case .bypassPermissions: "bypassPermissions"
      }
    }()

    let body = UpdateSettingsBody(
      providerStrategy: providerStrategy,
      primaryProvider: primaryProvider,
      secondaryProvider: secondaryProvider.isEmpty ? .some(nil) : .some(secondaryProvider),
      maxConcurrent: maxConcurrent,
      maxConcurrentPrimary: providerStrategy == "priority" ? .some(maxConcurrentPrimary) : .some(nil),
      agentClaudeModel: .some(claudeModel.isEmpty ? nil : claudeModel),
      agentClaudeEffort: .some(claudeEffort.serialized),
      agentClaudePermissionMode: .some(permissionWire),
      agentClaudeAllowedTools: parseCSV(claudeAllowedTools),
      agentClaudeDisallowedTools: parseCSV(claudeDisallowedTools),
      agentClaudeAllowBypassPermissions: claudeAllowBypass,
      agentCodexModel: .some(codexModel.isEmpty ? nil : codexModel),
      agentCodexEffort: .some(codexEffort.serialized),
      agentCodexApprovalPolicy: .some(codexAutonomy.approvalPolicy),
      agentCodexSandboxMode: .some(codexAutonomy.sandboxMode),
      agentCodexCollaborationMode: .some(codexCollaboration == .default ? nil : codexCollaboration.rawValue),
      agentCodexMultiAgent: .some(codexMultiAgent ? true : nil),
      agentCodexDevInstructions: .some(codexDevInstructions.isEmpty ? nil : codexDevInstructions),
      triggerKind: triggerKind,
      pollInterval: pollInterval,
      labelFilter: parseCSV(editLabels),
      stateFilter: parseCSV(editStates),
      projectKey: editProject.isEmpty ? .some(nil) : .some(editProject),
      teamKey: editTeam.isEmpty ? .some(nil) : .some(editTeam),
      maxRetries: maxRetries,
      stallTimeout: stallTimeout,
      baseBranch: baseBranch,
      worktreeRootDir: worktreeRootDir.isEmpty ? .some(nil) : .some(worktreeRootDir),
      stateOnDispatch: stateOnDispatch,
      stateOnComplete: stateOnComplete,
      promptTemplate: nil
    )

    do {
      let response: SettingsUpdateResponse = try await http.request(
        path: "/api/missions/\(missionId)/settings",
        method: "PUT",
        body: body
      )
      withAnimation(Motion.standard) { showSaveConfirmation = true }
      confirmationTask?.cancel()
      confirmationTask = Task {
        try? await Task.sleep(for: .seconds(3))
        if !Task.isCancelled {
          withAnimation(Motion.standard) { showSaveConfirmation = false }
        }
      }
      if let saved = response.settings {
        populateFromResponse(saved)
      }
      await onUpdated()
    } catch {
      saveError = "Save failed: \(error.localizedDescription)"
    }

    isSaving = false
  }
}

// MARK: - Network Types

private struct UpdateSettingsBody: Encodable {
  let providerStrategy: String?
  let primaryProvider: String?
  let secondaryProvider: OptionalString?
  let maxConcurrent: UInt32?
  let maxConcurrentPrimary: OptionalUInt32?
  let agentClaudeModel: OptionalString?
  let agentClaudeEffort: OptionalString?
  let agentClaudePermissionMode: OptionalString?
  let agentClaudeAllowedTools: [String]?
  let agentClaudeDisallowedTools: [String]?
  let agentClaudeAllowBypassPermissions: Bool?
  let agentCodexModel: OptionalString?
  let agentCodexEffort: OptionalString?
  let agentCodexApprovalPolicy: OptionalString?
  let agentCodexSandboxMode: OptionalString?
  let agentCodexCollaborationMode: OptionalString?
  let agentCodexMultiAgent: OptionalBool?
  let agentCodexDevInstructions: OptionalString?
  let triggerKind: String?
  let pollInterval: UInt64?
  let labelFilter: [String]?
  let stateFilter: [String]?
  let projectKey: OptionalString?
  let teamKey: OptionalString?
  let maxRetries: UInt32?
  let stallTimeout: UInt64?
  let baseBranch: String?
  let worktreeRootDir: OptionalString?
  let stateOnDispatch: String?
  let stateOnComplete: String?
  let promptTemplate: String?

  enum CodingKeys: String, CodingKey {
    case providerStrategy = "provider_strategy"
    case primaryProvider = "primary_provider"
    case secondaryProvider = "secondary_provider"
    case maxConcurrent = "max_concurrent"
    case maxConcurrentPrimary = "max_concurrent_primary"
    case agentClaudeModel = "agent_claude_model"
    case agentClaudeEffort = "agent_claude_effort"
    case agentClaudePermissionMode = "agent_claude_permission_mode"
    case agentClaudeAllowedTools = "agent_claude_allowed_tools"
    case agentClaudeDisallowedTools = "agent_claude_disallowed_tools"
    case agentClaudeAllowBypassPermissions = "agent_claude_allow_bypass_permissions"
    case agentCodexModel = "agent_codex_model"
    case agentCodexEffort = "agent_codex_effort"
    case agentCodexApprovalPolicy = "agent_codex_approval_policy"
    case agentCodexSandboxMode = "agent_codex_sandbox_mode"
    case agentCodexCollaborationMode = "agent_codex_collaboration_mode"
    case agentCodexMultiAgent = "agent_codex_multi_agent"
    case agentCodexDevInstructions = "agent_codex_developer_instructions"
    case triggerKind = "trigger_kind"
    case pollInterval = "poll_interval"
    case labelFilter = "label_filter"
    case stateFilter = "state_filter"
    case projectKey = "project_key"
    case teamKey = "team_key"
    case maxRetries = "max_retries"
    case stallTimeout = "stall_timeout"
    case baseBranch = "base_branch"
    case worktreeRootDir = "worktree_root_dir"
    case stateOnDispatch = "state_on_dispatch"
    case stateOnComplete = "state_on_complete"
    case promptTemplate = "prompt_template"
  }
}

private enum OptionalString: Encodable {
  case some(String)
  case none

  static func some(_ value: String?) -> OptionalString {
    if let value { .some(value) } else { .none }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
      case let .some(value): try container.encode(value)
      case .none: try container.encodeNil()
    }
  }
}

private enum OptionalBool: Encodable {
  case some(Bool)
  case none

  static func some(_ value: Bool?) -> OptionalBool {
    if let value { .some(value) } else { .none }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
      case let .some(value): try container.encode(value)
      case .none: try container.encodeNil()
    }
  }
}

private enum OptionalUInt32: Encodable {
  case some(UInt32)
  case none

  static func some(_ value: UInt32?) -> OptionalUInt32 {
    if let value { .some(value) } else { .none }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
      case let .some(value): try container.encode(value)
      case .none: try container.encodeNil()
    }
  }
}

private struct SettingsUpdateResponse: Decodable {
  let summary: MissionSummary
  let settings: MissionSettings?

  enum CodingKeys: String, CodingKey {
    case summary, settings
  }
}
