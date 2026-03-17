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
  @State private var showFullTemplate = false

  /// Prompt (read-only preview)
  @AppStorage("preferredEditor") private var preferredEditor: String = ""

  @State private var trackerKeyConfigured = false
  @State private var trackerKeySource: String?
  @State private var newApiKey = ""
  @State private var isSavingKey = false
  @State private var keyError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: isCompact ? Spacing.lg : Spacing.xl) {
      // Tracker connection — server-side, not in MISSION.md
      trackerConnectionSection

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
        // Mobile: everything stacks
        providerSection
        agentSection
        triggerSection
        orchestrationSection
      } else {
        // Desktop row 1: Provider + Agent
        HStack(alignment: .top, spacing: Spacing.sm) {
          providerSection
          agentSection
        }

        // Desktop row 2: Trigger + Orchestration
        HStack(alignment: .top, spacing: Spacing.sm) {
          triggerSection
          orchestrationSection
        }
      }

      promptSection

      saveFooter
    }
    .onAppear {
      populateFromSettings()
      Task { await fetchTrackerKeyStatus() }
    }
    .onChange(of: settings) { _, _ in populateFromSettings() }
  }

  // MARK: - Tracker Connection

  private var trackerConnectionSection: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm_) {
        Image(systemName: "link")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(Color.accent)
        Text("Tracker Connection")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
        Spacer()
        Text("Stored on server")
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textQuaternary)
      }

      if trackerKeyConfigured {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 12))
            .foregroundStyle(Color.feedbackPositive)

          VStack(alignment: .leading, spacing: 2) {
            Text("Linear API key configured")
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.textPrimary)

            if let source = trackerKeySource {
              Text("Source: \(source == "env" ? "LINEAR_API_KEY environment variable" : "saved in OrbitDock")")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textTertiary)
            }
          }

          Spacer()

          if trackerKeySource != "env" {
            Button {
              Task { await deleteTrackerKey() }
            } label: {
              Text("Remove")
                .font(.system(size: TypeScale.micro, weight: .medium))
                .foregroundStyle(Color.feedbackNegative)
            }
            .buttonStyle(.plain)
          }
        }
      } else {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundStyle(Color.feedbackCaution)
          Text("Linear API key required to poll for issues")
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textSecondary)
        }

        HStack(spacing: Spacing.sm) {
          SecureField("lin_api_...", text: $newApiKey)
            .textFieldStyle(.plain)
            .font(.system(size: TypeScale.caption, design: .monospaced))
            .padding(Spacing.sm)
            .background(
              RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(Color.backgroundTertiary)
            )

          Button {
            Task { await saveTrackerKey() }
          } label: {
            Group {
              if isSavingKey {
                ProgressView().controlSize(.small)
              } else {
                Text("Save")
                  .font(.system(size: TypeScale.caption, weight: .semibold))
              }
            }
            .foregroundStyle(newApiKey.isEmpty ? Color.textTertiary : .white)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .background(
              RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(newApiKey.isEmpty ? Color.backgroundTertiary : Color.accent)
            )
          }
          .buttonStyle(.plain)
          .disabled(newApiKey.isEmpty || isSavingKey)
        }
      }

      if let keyError {
        Text(keyError)
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.feedbackNegative)
      }
    }
    .padding(Spacing.lg)
    .background(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(Color.backgroundSecondary)
        .overlay(
          RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
            .strokeBorder(Color.surfaceBorder, lineWidth: 1)
        )
    )
  }

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

  private func saveTrackerKey() async {
    guard let http, !newApiKey.isEmpty else { return }
    isSavingKey = true
    keyError = nil
    do {
      let _: LinearKeyResponse = try await http.post(
        "/api/server/linear-key",
        body: SetLinearKeyBody(key: newApiKey)
      )
      newApiKey = ""
      trackerKeyConfigured = true
      trackerKeySource = "settings"
      await onUpdated()
    } catch {
      keyError = "Failed to save: \(error.localizedDescription)"
    }
    isSavingKey = false
  }

  private func deleteTrackerKey() async {
    guard let http else { return }
    do {
      let _: LinearKeyResponse = try await http.request(
        path: "/api/server/linear-key",
        method: "DELETE"
      )
      trackerKeyConfigured = false
      trackerKeySource = nil
      await onUpdated()
    } catch {
      keyError = "Failed to remove: \(error.localizedDescription)"
    }
  }

  // MARK: - Provider Section

  private var providerSection: some View {
    instrumentPanel(
      title: "Provider",
      icon: "cpu",
      description: "Which AI agents handle your issues"
    ) {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        // Strategy
        VStack(alignment: .leading, spacing: Spacing.sm_) {
          sectionLabel("Dispatch Strategy")

          VStack(spacing: Spacing.xs) {
            strategyOption(
              title: "Single",
              description: "One provider handles all issues",
              value: "single"
            )
            strategyOption(
              title: "Priority",
              description: "Primary first, overflow to secondary",
              value: "priority"
            )
            strategyOption(
              title: "Round Robin",
              description: "Alternate between providers",
              value: "round_robin"
            )
          }
        }

        ProviderSelectionGroup(
          strategy: $providerStrategy,
          primary: $primaryProvider,
          secondary: $secondaryProvider,
          includeStrategy: false,
          useCardStyle: true
        )

        // Concurrency
        concurrencyStepper("Max Concurrent", value: $maxConcurrent, range: 1 ... 20)

        if providerStrategy == "priority" {
          concurrencyStepper("Primary Limit", value: $maxConcurrentPrimary, range: 1 ... 20)
        }
      }
    }
  }

  // MARK: - Agent Section

  private var isClaudeActive: Bool {
    primaryProvider == "claude" || providerStrategy != "single"
  }

  private var isCodexActive: Bool {
    primaryProvider == "codex" || providerStrategy != "single"
  }

  private var agentSection: some View {
    instrumentPanel(
      title: "Agent",
      icon: "gearshape",
      description: "Model, effort, and permissions for dispatched agents"
    ) {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        // Headless context hint
        HStack(spacing: Spacing.sm_) {
          Image(systemName: "bolt.circle.fill")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.feedbackCaution)
          Text("Mission agents run autonomously — only headless-safe permission modes are available.")
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }

        claudeAgentSubsection
          .opacity(isClaudeActive ? 1 : 0.4)
          .allowsHitTesting(isClaudeActive)
          .overlay(alignment: .topTrailing) {
            if !isClaudeActive {
              inactiveProviderBadge
            }
          }

        // Divider between provider subsections
        HStack(spacing: Spacing.md) {
          Rectangle()
            .fill(Color.surfaceBorder.opacity(OpacityTier.medium))
            .frame(height: 1)
        }
        .padding(.vertical, Spacing.xs)

        codexAgentSubsection
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

  // MARK: Claude Agent Subsection

  private var claudeAgentSubsection: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      // Subsection header
      providerSubheader("Claude", icon: "cpu", color: .providerClaude)

      compactField("Model", placeholder: "claude-sonnet-4-6", text: $claudeModel)

      // Effort + Permission side by side on desktop
      if isCompact {
        effortRow("Effort", binding: $claudeEffort)
        permissionRow
      } else {
        HStack(alignment: .top, spacing: Spacing.lg) {
          effortRow("Effort", binding: $claudeEffort)
          permissionRow
        }
      }

      // Tool restrictions side by side on desktop
      if isCompact {
        compactField("Allowed Tools", placeholder: "Read, Edit, Bash(git:*)", text: $claudeAllowedTools)
        compactField("Disallowed Tools", placeholder: "Bash(rm:*)", text: $claudeDisallowedTools)
      } else {
        HStack(alignment: .top, spacing: Spacing.sm) {
          compactField("Allowed Tools", placeholder: "Read, Edit, Bash(git:*)", text: $claudeAllowedTools)
          compactField("Disallowed Tools", placeholder: "Bash(rm:*)", text: $claudeDisallowedTools)
        }
      }
    }
  }

  private var permissionRow: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      sectionLabel("Permission")

      // Only mission-safe modes — plan/default/don't-ask would stall headless agents
      WrappingFlowLayout(spacing: Spacing.xs) {
        permissionChip(.acceptEdits)
        permissionChip(.bypassPermissions)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: Codex Agent Subsection

  private var codexAgentSubsection: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      // Subsection header
      providerSubheader("Codex", icon: "terminal", color: .providerCodex)

      compactField("Model", placeholder: "gpt-5.3-codex", text: $codexModel)

      // Effort + Autonomy side by side on desktop
      if isCompact {
        effortRow("Effort", binding: $codexEffort)
        autonomyRow
      } else {
        HStack(alignment: .top, spacing: Spacing.lg) {
          effortRow("Effort", binding: $codexEffort)
          autonomyRow
        }
      }

      // Multi-agent + Collaboration on same row
      if isCompact {
        multiAgentToggleRow
        collaborationRow
      } else {
        HStack(alignment: .top, spacing: Spacing.lg) {
          collaborationRow
          multiAgentToggleRow
        }
      }

      compactField("Developer Instructions", placeholder: "Be concise and pragmatic", text: $codexDevInstructions)
    }
  }

  private var autonomyRow: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      sectionLabel("Autonomy")

      // Only mission-safe levels — locked/guarded would stall headless agents
      WrappingFlowLayout(spacing: Spacing.xs) {
        autonomyChip(.autonomous)
        autonomyChip(.fullAuto)
        autonomyChip(.open)
        autonomyChip(.unrestricted)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var multiAgentToggleRow: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      sectionLabel("Multi-Agent")

      HStack(spacing: Spacing.sm) {
        Toggle("", isOn: $codexMultiAgent)
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.mini)

        Text(codexMultiAgent ? "Enabled" : "Disabled")
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(codexMultiAgent ? Color.accent : Color.textQuaternary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var collaborationRow: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      sectionLabel("Collaboration")

      HStack(spacing: Spacing.sm) {
        collaborationButton(.default)
        collaborationButton(.plan)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Agent Component Helpers

  private func providerSubheader(_ name: String, icon: String, color: Color) -> some View {
    HStack(spacing: Spacing.sm_) {
      RoundedRectangle(cornerRadius: 1, style: .continuous)
        .fill(color)
        .frame(width: 2, height: 12)

      Image(systemName: icon)
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(color)
      Text(name)
        .font(.system(size: TypeScale.caption, weight: .bold))
        .foregroundStyle(color)
    }
  }

  private func effortRow(_ label: String, binding: Binding<EffortLevel>) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      sectionLabel(label)

      WrappingFlowLayout(spacing: Spacing.xs) {
        effortChip(.default, binding: binding)
        effortChip(.low, binding: binding)
        effortChip(.medium, binding: binding)
        effortChip(.high, binding: binding)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func permissionChip(_ mode: ClaudePermissionMode) -> some View {
    let isSelected = claudePermission == mode

    let label: String = isCompact ? {
      switch mode {
        case .plan: "Plan"
        case .dontAsk: "Don't Ask"
        case .default: "Default"
        case .acceptEdits: "Edits"
        case .bypassPermissions: "Bypass"
      }
    }() : mode.displayName

    return Button {
      claudePermission = mode
    } label: {
      SelectableOptionChip(
        label: label,
        icon: mode.icon,
        isSelected: isSelected,
        tint: mode.color,
        isCompact: isCompact
      )
    }
    .buttonStyle(.plain)
  }

  private func autonomyChip(_ level: AutonomyLevel) -> some View {
    let isSelected = codexAutonomy == level

    let label: String = isCompact ? {
      switch level {
        case .locked: "Locked"
        case .guarded: "Guard"
        case .autonomous: "Auto"
        case .fullAuto: "Full"
        case .open: "Open"
        case .unrestricted: "None"
      }
    }() : level.displayName

    return Button {
      codexAutonomy = level
    } label: {
      SelectableOptionChip(
        label: label,
        icon: level.icon,
        isSelected: isSelected,
        tint: level.color,
        isCompact: isCompact
      )
    }
    .buttonStyle(.plain)
  }

  private func effortChip(_ level: EffortLevel, binding: Binding<EffortLevel>) -> some View {
    let isSelected = binding.wrappedValue == level
    let tint = level == .default ? Color.accent : level.color

    return Button {
      binding.wrappedValue = level
    } label: {
      SelectableOptionChip(
        label: level.displayName,
        isSelected: isSelected,
        tint: tint
      )
    }
    .buttonStyle(.plain)
  }

  private func collaborationButton(_ mode: CodexCollaborationMode) -> some View {
    let isSelected = codexCollaboration == mode

    return Button {
      withAnimation(Motion.snappy) { codexCollaboration = mode }
    } label: {
      SelectableOptionChip(
        label: mode.displayName,
        icon: mode.icon,
        isSelected: isSelected,
        tint: mode.color
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Trigger Section

  private var triggerSection: some View {
    instrumentPanel(
      title: "Trigger",
      icon: "antenna.radiowaves.left.and.right",
      description: "When and which issues to process"
    ) {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        // Kind
        VStack(alignment: .leading, spacing: Spacing.sm_) {
          sectionLabel("Mode")

          HStack(spacing: Spacing.sm) {
            modeButton("Polling", icon: "arrow.clockwise", value: "polling", selected: triggerKind) {
              triggerKind = "polling"
            }
            modeButton("Manual", icon: "hand.tap", value: "manual_only", selected: triggerKind) {
              triggerKind = "manual_only"
            }
          }
        }

        if triggerKind == "polling" {
          VStack(alignment: .leading, spacing: Spacing.sm_) {
            sectionLabel("Poll Interval")

            WrappingFlowLayout(spacing: Spacing.xs) {
              intervalChip("30s", seconds: 30)
              intervalChip("1m", seconds: 60)
              intervalChip("5m", seconds: 300)
              intervalChip("15m", seconds: 900)
            }
          }
        }

        // Filters
        VStack(alignment: .leading, spacing: Spacing.sm_) {
          sectionLabel("Filters")

          if isCompact {
            compactField("Project", placeholder: "PROJ", text: $editProject)
            compactField("Team", placeholder: "Engineering", text: $editTeam)
          } else {
            HStack(alignment: .top, spacing: Spacing.sm) {
              compactField("Project", placeholder: "PROJ", text: $editProject)
              compactField("Team", placeholder: "Engineering", text: $editTeam)
            }
          }

          compactField("Labels", placeholder: "bug, agent-ready", text: $editLabels)
          compactField("States", placeholder: "Todo, In Progress", text: $editStates)

          Text("Common states: Todo, In Progress, Done, Canceled")
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textQuaternary)
        }
      }
    }
  }

  // MARK: - Orchestration Section

  private var orchestrationSection: some View {
    instrumentPanel(
      title: "Orchestration",
      icon: "gearshape.2",
      description: "Retry, timeout, and branch settings"
    ) {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        concurrencyStepper("Max Retries", value: $maxRetries, range: 0 ... 10)

        VStack(alignment: .leading, spacing: Spacing.sm_) {
          sectionLabel("Stall Timeout")

          WrappingFlowLayout(spacing: Spacing.xs) {
            intervalChip("5m", seconds: 300, current: stallTimeout) { stallTimeout = 300 }
            intervalChip("10m", seconds: 600, current: stallTimeout) { stallTimeout = 600 }
            intervalChip("30m", seconds: 1_800, current: stallTimeout) { stallTimeout = 1_800 }
            intervalChip("1h", seconds: 3_600, current: stallTimeout) { stallTimeout = 3_600 }
          }
        }

        compactField("Base Branch", placeholder: "main", text: $baseBranch)
        compactField("Worktree Root", placeholder: ".orbitdock-worktrees (default)", text: $worktreeRootDir)

        HStack(spacing: Spacing.sm_) {
          Image(systemName: "folder")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.textQuaternary)

          Text(repoRoot)
            .font(.system(size: TypeScale.micro, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
            .fixedSize(horizontal: false, vertical: true)

          #if os(macOS)
            Spacer()

            Button {
              NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repoRoot)
            } label: {
              Image(systemName: "arrow.up.right.square")
                .font(.system(size: 9))
                .foregroundStyle(Color.textQuaternary)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
          #endif
        }
      }
    }
  }

  // MARK: - Prompt Template Preview

  private var promptSection: some View {
    let templateText = settings?.promptTemplate ?? ""
    let previewLines = templateText.split(separator: "\n", omittingEmptySubsequences: false).prefix(6)
    let hasContent = !templateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    let totalLines = templateText.split(separator: "\n", omittingEmptySubsequences: false).count
    let isLong = totalLines > 6

    return instrumentPanel(
      title: "Agent Instructions",
      icon: "text.bubble",
      description: "What each agent is told when it picks up an issue"
    ) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        if hasContent {
          // Line count badge
          HStack(spacing: Spacing.sm_) {
            Image(systemName: "doc.text")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(Color.textQuaternary)
            Text("\(totalLines) lines")
              .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
              .foregroundStyle(Color.textTertiary)

            if isLong {
              Text("·")
                .foregroundStyle(Color.textQuaternary)
              Button {
                withAnimation(Motion.standard) {
                  showFullTemplate.toggle()
                }
              } label: {
                Text(showFullTemplate ? "Collapse" : "Expand preview")
                  .font(.system(size: TypeScale.micro, weight: .medium))
                  .foregroundStyle(Color.accent)
              }
              .buttonStyle(.plain)
            }
          }

          // Template preview
          ScrollView {
            VStack(alignment: .leading, spacing: 2) {
              let lines = showFullTemplate
                ? templateText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                : previewLines.map(String.init)

              ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                  .font(.system(size: TypeScale.micro, design: .monospaced))
                  .foregroundStyle(Color.textSecondary)
              }

              if !showFullTemplate, isLong {
                Text("...")
                  .font(.system(size: TypeScale.micro, design: .monospaced))
                  .foregroundStyle(Color.textQuaternary)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: showFullTemplate ? 400 : nil)
          .padding(Spacing.md)
          .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              .fill(Color.backgroundPrimary)
              .overlay(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                  .strokeBorder(Color.surfaceBorder, lineWidth: 1)
              )
          )
        } else {
          HStack(spacing: Spacing.sm) {
            Image(systemName: "doc.text.magnifyingglass")
              .font(.system(size: 12))
              .foregroundStyle(Color.textQuaternary)
            Text("No prompt template configured")
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textTertiary)
          }
          .padding(Spacing.md)
        }

        // Action row
        HStack(spacing: Spacing.md) {
          #if os(macOS)
            Button {
              openMissionFileInEditor()
            } label: {
              HStack(spacing: Spacing.sm_) {
                Image(systemName: "pencil.and.outline")
                  .font(.system(size: 11, weight: .semibold))
                Text("Edit in \(editorName)")
                  .font(.system(size: TypeScale.caption, weight: .medium))
              }
              .foregroundStyle(Color.accent)
            }
            .buttonStyle(.plain)

            Button {
              let path = repoRoot.hasSuffix("/") ? repoRoot + "MISSION.md" : repoRoot + "/MISSION.md"
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(path, forType: .string)
            } label: {
              HStack(spacing: Spacing.sm_) {
                Image(systemName: "doc.on.clipboard")
                  .font(.system(size: 11, weight: .semibold))
                Text("Copy Path")
                  .font(.system(size: TypeScale.caption, weight: .medium))
              }
              .foregroundStyle(Color.textSecondary)
            }
            .buttonStyle(.plain)
          #endif

          Spacer()

          if !isCompact {
            HStack(spacing: Spacing.sm) {
              variableTag("issue.identifier")
              variableTag("issue.title")
              variableTag("attempt")
              Text("+3 more")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textQuaternary)
            }
          }
        }

        HStack(spacing: Spacing.sm_) {
          Image(systemName: "info.circle")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
          Text("This is what each agent receives when dispatched to an issue. Review before starting the orchestrator.")
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textQuaternary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private func variableTag(_ name: String) -> some View {
    Text("{{ \(name) }}")
      .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
      .foregroundStyle(Color.accent.opacity(OpacityTier.strong))
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, 2)
      .background(
        Color.accent.opacity(OpacityTier.subtle),
        in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
      )
  }

  private var editorName: String {
    switch preferredEditor {
      case "code": "VS Code"
      case "cursor": "Cursor"
      case "zed": "Zed"
      case "subl": "Sublime"
      case "emacs": "Emacs"
      case "vim": "Vim"
      case "nvim": "Neovim"
      default: "Editor"
    }
  }

  private func openMissionFileInEditor() {
    let missionPath = repoRoot.hasSuffix("/")
      ? repoRoot + "MISSION.md"
      : repoRoot + "/MISSION.md"

    #if os(macOS)
      if !preferredEditor.isEmpty {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [preferredEditor, missionPath]
        try? process.run()
      } else {
        NSWorkspace.shared.open(URL(fileURLWithPath: missionPath))
      }
    #else
      // iOS: can't open local files in external editors, but the preview still works
    #endif
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
        // Where it saves indicator
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

  // MARK: - Instrument Panel

  private func instrumentPanel<Content: View>(
    title: String,
    icon: String,
    description: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header with accent edge
      HStack(spacing: 0) {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
          .fill(Color.accent)
          .frame(width: EdgeBar.width)
          .padding(.vertical, Spacing.sm)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          HStack(spacing: Spacing.sm_) {
            Image(systemName: icon)
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(Color.accent)
            Text(title)
              .font(.system(size: TypeScale.body, weight: .bold))
              .foregroundStyle(Color.textPrimary)
          }

          if !isCompact {
            Text(description)
              .font(.system(size: TypeScale.micro))
              .foregroundStyle(Color.textQuaternary)
          }
        }
        .padding(.leading, Spacing.md)
      }
      .padding(.horizontal, isCompact ? Spacing.md : Spacing.lg)
      .padding(.vertical, isCompact ? Spacing.sm : Spacing.md)

      Divider()
        .foregroundStyle(Color.surfaceBorder.opacity(OpacityTier.subtle))

      // Content
      content()
        .padding(isCompact ? Spacing.md : Spacing.lg)
    }
    .fixedSize(horizontal: false, vertical: true)
    .background(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(Color.backgroundSecondary)
        .overlay(
          RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
            .strokeBorder(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
        )
    )
  }

  // MARK: - Shared Components

  private func sectionLabel(_ text: String) -> some View {
    Text(text.uppercased())
      .font(.system(size: TypeScale.micro, weight: .bold))
      .foregroundStyle(Color.textQuaternary)
      .tracking(0.6)
  }

  private func strategyOption(title: String, description: String, value: String) -> some View {
    Button {
      withAnimation(Motion.snappy) { providerStrategy = value }
    } label: {
      HStack(spacing: Spacing.md) {
        // Radio indicator
        ZStack {
          Circle()
            .strokeBorder(providerStrategy == value ? Color.accent : Color.textQuaternary, lineWidth: 1.5)
            .frame(width: 14, height: 14)

          if providerStrategy == value {
            Circle()
              .fill(Color.accent)
              .frame(width: 7, height: 7)
          }
        }

        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(providerStrategy == value ? Color.textPrimary : Color.textSecondary)

          Text(description)
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textQuaternary)
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .fill(providerStrategy == value ? Color.accent.opacity(OpacityTier.subtle) : Color.backgroundTertiary
            .opacity(0.5))
          .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              .strokeBorder(providerStrategy == value ? Color.accent.opacity(OpacityTier.light) : .clear, lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
  }

  private func modeButton(
    _ label: String,
    icon: String,
    value: String,
    selected: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      SelectableOptionChip(
        label: label,
        icon: icon,
        isSelected: selected == value
      )
    }
    .buttonStyle(.plain)
  }

  private func compactField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textTertiary)

      TextField(placeholder, text: text)
        .textFieldStyle(.plain)
        .font(.system(size: TypeScale.caption, design: .monospaced))
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm_)
        .background(
          RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(Color.backgroundPrimary)
            .overlay(
              RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(Color.surfaceBorder, lineWidth: 1)
            )
        )
    }
  }

  private func concurrencyStepper(_ label: String, value: Binding<UInt32>, range: ClosedRange<UInt32>) -> some View {
    HStack(spacing: Spacing.md) {
      Text(label)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textTertiary)

      Spacer()

      HStack(spacing: 0) {
        Button {
          if value.wrappedValue > range.lowerBound {
            value.wrappedValue -= 1
          }
        } label: {
          Image(systemName: "minus")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(value.wrappedValue > range.lowerBound ? Color.textSecondary : Color.textQuaternary)
            .frame(width: 28, height: 26)
            .background(Color.backgroundTertiary)
        }
        .buttonStyle(.plain)

        Text("\(value.wrappedValue)")
          .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.textPrimary)
          .frame(width: 32, height: 26)
          .background(Color.backgroundPrimary)

        Button {
          if value.wrappedValue < range.upperBound {
            value.wrappedValue += 1
          }
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(value.wrappedValue < range.upperBound ? Color.textSecondary : Color.textQuaternary)
            .frame(width: 28, height: 26)
            .background(Color.backgroundTertiary)
        }
        .buttonStyle(.plain)
      }
      .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .strokeBorder(Color.surfaceBorder, lineWidth: 1)
      )
    }
  }

  private func intervalChip(_ label: String, seconds: UInt64) -> some View {
    Button {
      pollInterval = seconds
    } label: {
      SelectableOptionChip(
        label: label,
        isSelected: pollInterval == seconds
      )
    }
    .buttonStyle(.plain)
  }

  private func intervalChip(
    _ label: String,
    seconds: UInt64,
    current: UInt64,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      SelectableOptionChip(
        label: label,
        isSelected: current == seconds
      )
    }
    .buttonStyle(.plain)
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

    // Agent — Claude
    if let claude = s.agent.claude {
      claudeModel = claude.model ?? ""
      claudeEffort = effortFromString(claude.effort)
      claudePermission = permissionFromString(claude.permissionMode)
      claudeAllowedTools = claude.allowedTools.joined(separator: ", ")
      claudeDisallowedTools = claude.disallowedTools.joined(separator: ", ")
    } else {
      claudeModel = ""
      claudeEffort = .default
      claudePermission = .acceptEdits // mission-safe default
      claudeAllowedTools = ""
      claudeDisallowedTools = ""
    }

    // Agent — Codex
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
      codexAutonomy = .autonomous // mission-safe default
      codexMultiAgent = false
      codexCollaboration = .default
      codexDevInstructions = ""
    }

    maxRetries = s.orchestration.maxRetries
    stallTimeout = s.orchestration.stallTimeout
    baseBranch = s.orchestration.baseBranch
    worktreeRootDir = s.orchestration.worktreeRootDir ?? ""
  }

  private func effortFromString(_ value: String?) -> EffortLevel {
    guard let value, !value.isEmpty else { return .default }
    return EffortLevel(rawValue: value) ?? .default
  }

  private func permissionFromString(_ value: String?) -> ClaudePermissionMode {
    guard let value, !value.isEmpty else { return .default }
    // Map wire values to enum cases
    switch value {
      case "plan": return .plan
      case "dont-ask": return .dontAsk
      case "default": return .default
      case "auto-edit", "acceptEdits": return .acceptEdits
      case "bypass", "bypassPermissions": return .bypassPermissions
      default: return .default
    }
  }

  private func parseCSV(_ text: String) -> [String] {
    text
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  private func saveSettings() async {
    guard let http else { return }

    isSaving = true
    saveError = nil
    showSaveConfirmation = false

    // Map permission mode to wire value
    let permissionWire: String? = claudePermission == .default ? nil : {
      switch claudePermission {
        case .plan: return "plan"
        case .dontAsk: return "dont-ask"
        case .default: return "default"
        case .acceptEdits: return "auto-edit"
        case .bypassPermissions: return "bypass"
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
      // Re-populate form from the response to avoid stale state
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
  // Agent — Claude
  let agentClaudeModel: OptionalString?
  let agentClaudeEffort: OptionalString?
  let agentClaudePermissionMode: OptionalString?
  let agentClaudeAllowedTools: [String]?
  let agentClaudeDisallowedTools: [String]?
  // Agent — Codex
  let agentCodexModel: OptionalString?
  let agentCodexEffort: OptionalString?
  let agentCodexApprovalPolicy: OptionalString?
  let agentCodexSandboxMode: OptionalString?
  let agentCodexCollaborationMode: OptionalString?
  let agentCodexMultiAgent: OptionalBool?
  let agentCodexDevInstructions: OptionalString?
  // Trigger + rest
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
