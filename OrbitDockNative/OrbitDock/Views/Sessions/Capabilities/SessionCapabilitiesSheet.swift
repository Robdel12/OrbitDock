import SwiftUI

struct SessionCapabilitiesSheet: View {
  @Environment(\.dismiss) private var dismiss

  let session: ServerSessionContext
  let projectPath: String
  let provider: Provider
  let sessionState: ServerSessionState?
  let model: SessionCapabilitiesModel

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          headerCard
          tabPicker
          content
        }
        .padding(Spacing.lg)
      }
      .background(Color.backgroundPrimary)
      .navigationTitle("Codex Runtime")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            Task {
              await model.refresh(
                session: session,
                projectPath: projectPath,
                sessionState: model.sessionState ?? sessionState,
                forceSkillReload: true
              )
            }
          } label: {
            if model.isLoading {
              ProgressView()
                .controlSize(.small)
            } else {
              Text("Refresh")
            }
          }
          .disabled(model.isLoading)
        }
      }
    }
    .frame(minWidth: 820, minHeight: 700)
    .task {
      model.syncSessionState(sessionState)
      await model.loadIfNeeded(
        session: session,
        projectPath: projectPath,
        sessionState: sessionState
      )
    }
  }

  private var headerCard: some View {
    card {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        HStack(alignment: .top, spacing: Spacing.md) {
          VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text("Provider")
              .font(.system(size: TypeScale.micro, weight: .semibold))
              .foregroundStyle(Color.textQuaternary)
            Text(provider == .codex ? "Codex app server" : provider.rawValue.capitalized)
              .font(.system(size: TypeScale.body, weight: .semibold))
              .foregroundStyle(Color.textPrimary)
          }

          Spacer()

          capabilityBadge(
            title: model.isStale ? "Needs Refresh" : "Live Snapshot",
            tint: model.isStale ? .feedbackCaution : .providerCodex
          )
        }

        Text(
          "Runtime state, collaboration presets, turn controls, plugin marketplaces, skills, and MCP inventory all come from the active session surfaces instead of local heuristics."
        )
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

        if let account = session.codexAccountStatus?.account {
          Text(accountSummary(account))
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }

        if let notice = model.notice, !notice.isEmpty {
          Text(notice)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.feedbackPositive)
            .fixedSize(horizontal: false, vertical: true)
        }

        if let error = model.lastError, !error.isEmpty {
          Text(error)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.feedbackNegative)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private var tabPicker: some View {
    Picker(
      "Runtime Surface",
      selection: Binding(
        get: { model.selectedTab },
        set: { model.selectedTab = $0 }
      )
    ) {
      ForEach(SessionCapabilitiesModel.Tab.allCases) { tab in
        Text(tabLabel(tab)).tag(tab)
      }
    }
    .pickerStyle(.segmented)
  }

  @ViewBuilder
  private var content: some View {
    switch model.selectedTab {
      case .runtime:
        runtimeSection
      case .plugins:
        pluginsSection
      case .skills:
        skillsSection
      case .mcp:
        mcpSection
    }
  }

  @ViewBuilder
  private var runtimeSection: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      runtimeSnapshotCard
      turnControlsCard
      collaborationModesCard
      instructionsCard
    }
  }

  private var runtimeSnapshotCard: some View {
    card(
      title: "Session Runtime",
      detail: "This view combines the authoritative session snapshot with Orbit's normalized control capabilities for the active provider."
    ) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        HStack(spacing: Spacing.sm) {
          metricPill(workStatusLabel, tint: workStatusTint)
          metricPill(inputStateLabel, tint: .statusReply)
          if let currentTurnId = model.sessionState?.currentTurnId, !currentTurnId.isEmpty {
            metricPill("Turn active", tint: .feedbackWarning)
          }
        }

        LazyVGrid(columns: runtimeColumns, alignment: .leading, spacing: Spacing.md) {
          runtimeValue("Collaboration", value: model.sessionState?.collaborationMode ?? "Default")
          runtimeValue("Model", value: model.sessionState?.model ?? "Unset")
          runtimeValue("Effort", value: model.sessionState?.effort ?? "Auto")
          runtimeValue("Turns", value: "\(model.sessionState?.turnCount ?? 0)")
          runtimeValue("Steer", value: (model.sessionState?.steerable ?? false) ? "Ready" : "Idle")
          runtimeValue(
            "Stop Turn",
            value: controlAvailabilityLabel(model.controls?.stopActiveTurn)
          )
          runtimeValue(
            "Rollback",
            value: controlAvailabilityLabel(model.controls?.rollbackTurns)
          )
        }
      }
    }
  }

  private var turnControlsCard: some View {
    card(
      title: "Turn Controls",
      detail: "Orbit normalizes shared session controls across providers, then surfaces any richer provider-specific targets when they exist."
    ) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        HStack(spacing: Spacing.sm) {
          actionButton(
            title: "Stop Turn",
            running: model.isInterrupting,
            tint: .feedbackNegative
          ) {
            Task { await model.interruptTurn(session: session) }
          }
          .disabled(!canStopActiveTurn || isAnyTurnActionRunning)

          actionButton(
            title: "Compact",
            running: model.isCompacting,
            tint: .providerCodex
          ) {
            Task { await model.compactContext(session: session) }
          }
          .disabled(!canCompactContext || isAnyTurnActionRunning)

          actionButton(
            title: "Undo",
            running: model.isUndoing,
            tint: .statusQuestion
          ) {
            Task { await model.undoLastTurn(session: session) }
          }
          .disabled(!canUndoLastTurn || isAnyTurnActionRunning)
        }

        HStack(alignment: .center, spacing: Spacing.md) {
          Stepper(
            value: Binding(
              get: { model.rollbackTurnCount },
              set: { model.rollbackTurnCount = $0 }
            ),
            in: 1...maxRollbackTurns
          ) {
            Text("Rollback \(model.rollbackTurnCount) \(model.rollbackTurnCount == 1 ? "turn" : "turns")")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(Color.textPrimary)
          }

          actionButton(
            title: "Rollback",
            running: model.isRollingBack,
            tint: .feedbackCaution
          ) {
            Task { await model.rollbackTurns(session: session) }
          }
          .disabled(!canRollbackTurns || isAnyTurnActionRunning)
        }

        HStack(spacing: Spacing.xs) {
          metricPill(
            supportsStopTarget ? "Stop target: \(stopTargetKindLabel)" : "No target stop",
            tint: supportsStopTarget ? .feedbackCaution : .textTertiary
          )
          metricPill(
            supportsRewindToMessage ? "Rewind target: Message" : "No message rewind",
            tint: supportsRewindToMessage ? .statusQuestion : .textTertiary
          )
        }

        Text(targetControlsDescription)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder
  private var collaborationModesCard: some View {
    if model.collaborationModes.isEmpty, !model.isLoading {
      card(
        title: "Collaboration Presets",
        detail: "The active Codex session did not report any collaboration masks."
      ) {
        Text("OrbitDock will keep using the current session setting until Codex reports presets for this runtime.")
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    } else {
      card(
        title: "Collaboration Presets",
        detail: "These presets come from the live Codex app server for the active session."
      ) {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          ForEach(model.collaborationModes) { mode in
            collaborationModeRow(mode)
          }
        }
      }
    }
  }

  private var instructionsCard: some View {
    card(
      title: "Instructions",
      detail: "Read-only merged prompt state for this session."
    ) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        instructionBlock(
          title: "Developer Instructions",
          value: model.instructions?.developerInstructions ?? model.sessionState?.developerInstructions
        )
        instructionBlock(
          title: "System Prompt",
          value: model.instructions?.systemPrompt
        )
        if let claudeMD = model.instructions?.claudeMD, !claudeMD.isEmpty {
          instructionBlock(title: "CLAUDE.md", value: claudeMD)
        }
      }
    }
  }

  @ViewBuilder
  private var pluginsSection: some View {
    if model.marketplaces.isEmpty, model.pluginLoadErrors.isEmpty, !model.isLoading {
      emptyState(
        title: "No plugin marketplaces available",
        message: "Codex didn't report any plugin catalogs for this workspace yet."
      )
    } else {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        if !model.pluginLoadErrors.isEmpty {
          card(
            title: "Marketplace Load Issues",
            detail: "OrbitDock keeps the good marketplaces and surfaces the ones Codex couldn't load."
          ) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
              ForEach(model.pluginLoadErrors) { error in
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                  Text(error.marketplacePath)
                    .font(.system(size: TypeScale.caption, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                  Text(error.message)
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(Color.feedbackCaution)
                }
              }
            }
          }
        }

        ForEach(model.marketplaces) { marketplace in
          card(
            title: marketplace.interface?.displayName ?? marketplace.name,
            detail: marketplace.path ?? "Remote marketplace"
          ) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
              ForEach(marketplace.plugins) { plugin in
                pluginRow(marketplace: marketplace, plugin: plugin)
              }
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var skillsSection: some View {
    let visibleEntries = model.skills.filter { !$0.skills.isEmpty || !$0.errors.isEmpty }

    if visibleEntries.isEmpty, model.skillErrors.isEmpty, !model.isLoading {
      emptyState(
        title: "No skills discovered",
        message: "OrbitDock can send skill references, but this workspace doesn't currently expose any model-visible skills."
      )
    } else {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        if !model.skillErrors.isEmpty {
          card(
            title: "Skill Resolution Issues",
            detail: "These entries couldn't be loaded cleanly from the paths Codex reported."
          ) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
              ForEach(Array(model.skillErrors.enumerated()), id: \.offset) { _, error in
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                  Text(error.path)
                    .font(.system(size: TypeScale.caption, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                  Text(error.message)
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(Color.feedbackCaution)
                }
              }
            }
          }
        }

        ForEach(Array(visibleEntries.enumerated()), id: \.offset) { _, entry in
          card(
            title: entry.cwd,
            detail: "\(entry.skills.count) skills"
          ) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
              ForEach(entry.skills) { skill in
                skillRow(skill)
              }
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var mcpSection: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      card(
        title: "MCP Servers",
        detail: "This is the live MCP inventory OrbitDock can see for the current Codex session."
      ) {
        HStack(spacing: Spacing.md) {
          capabilityBadge(title: "\(model.mcpServers.count) servers", tint: .toolMcp)
          Button {
            Task { await model.refreshMcp(session: session, projectPath: projectPath) }
          } label: {
            if model.isRefreshingMcp {
              ProgressView()
                .controlSize(.small)
            } else {
              Text("Refresh MCP")
            }
          }
          .buttonStyle(.bordered)
          .disabled(model.isRefreshingMcp)
        }
      }

      if model.mcpServers.isEmpty, !model.isLoading {
        emptyState(
          title: "No MCP servers reported",
          message: "If you expected one here, check your Codex config, account mode, and installed plugins."
        )
      } else {
        ForEach(Array(model.mcpServers.enumerated()), id: \.element.id) { _, server in
          card(
            title: server.name,
            detail: authLabel(server.authStatus)
          ) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
              HStack(spacing: Spacing.sm) {
                metricPill("\(server.tools.count) tools", tint: .toolMcp)
                metricPill("\(server.resources.count) resources", tint: .statusWorking)
                metricPill("\(server.resourceTemplates.count) templates", tint: .providerCodex)
              }

              if !server.tools.isEmpty {
                horizontalPillRow(server.tools, id: \.name) { tool in
                  metricPill(tool.title ?? tool.name, tint: .toolMcp, monospaced: true)
                }
              }

              if !server.resources.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                  Text("Resources")
                    .font(.system(size: TypeScale.caption, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                  ForEach(server.resources, id: \.uri) { resource in
                    Text(resource.title ?? resource.name)
                      .font(.system(size: TypeScale.caption, design: .monospaced))
                      .foregroundStyle(Color.textTertiary)
                      .lineLimit(1)
                      .truncationMode(.middle)
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  private func pluginRow(
    marketplace: ServerPluginMarketplaceEntry,
    plugin: ServerPluginSummary
  ) -> some View {
    let displayName = model.displayName(for: plugin)
    let isInstalling = model.installingPluginIDs.contains(plugin.id)
    let isUninstalling = model.uninstallingPluginIDs.contains(plugin.id)

    return VStack(alignment: .leading, spacing: Spacing.sm_) {
      HStack(alignment: .top, spacing: Spacing.md) {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          HStack(spacing: Spacing.xs) {
            Text(displayName)
              .font(.system(size: TypeScale.body, weight: .semibold))
              .foregroundStyle(Color.textPrimary)
            if model.isFeatured(plugin) {
              metricPill("Featured", tint: .accent)
            }
            if plugin.installed {
              metricPill(plugin.enabled ? "Installed" : "Disabled", tint: .feedbackPositive)
            }
          }

          if let shortDescription = plugin.interface?.shortDescription, !shortDescription.isEmpty {
            Text(shortDescription)
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          HStack(spacing: Spacing.xs) {
            metricPill(plugin.installPolicyLabel, tint: .providerCodex)
            metricPill(plugin.authPolicyLabel, tint: .providerCodex)
            if let category = plugin.interface?.category, !category.isEmpty {
              metricPill(category, tint: .textTertiary)
            }
          }
        }

        Spacer(minLength: 0)

        if plugin.installed {
          Button {
            Task { await model.uninstallPlugin(plugin: plugin, session: session, projectPath: projectPath) }
          } label: {
            if isUninstalling {
              ProgressView()
                .controlSize(.small)
            } else {
              Text("Uninstall")
            }
          }
          .buttonStyle(.bordered)
          .disabled(isInstalling || isUninstalling)
        } else {
          Button {
            Task {
              await model.installPlugin(
                marketplace: marketplace,
                plugin: plugin,
                session: session,
                projectPath: projectPath
              )
            }
          } label: {
            if isInstalling {
              ProgressView()
                .controlSize(.small)
            } else {
              Text("Install")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isInstalling || isUninstalling || plugin.installPolicy == .notAvailable)
          .tint(Color.accent)
        }
      }

      if let capabilities = plugin.interface?.capabilities, !capabilities.isEmpty {
        horizontalPillRow(capabilities, id: \.self) { capability in
          metricPill(capability, tint: .providerCodex)
        }
      }
    }
    .padding(.vertical, Spacing.xs)
  }

  private func skillRow(_ skill: ServerSkillMetadata) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(alignment: .top, spacing: Spacing.md) {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(skill.interface?.displayName ?? skill.name)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text(skill.interface?.shortDescription ?? skill.shortDescription ?? skill.description)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 0)

        HStack(spacing: Spacing.xs) {
          metricPill(skill.scope.label, tint: .providerCodex)
          metricPill(skill.enabled ? "Enabled" : "Disabled", tint: skill.enabled ? .feedbackPositive : .feedbackCaution)
        }
      }

      Text(skill.path)
        .font(.system(size: TypeScale.micro, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)

      if let tools = skill.dependencies?.tools, !tools.isEmpty {
        horizontalPillRow(tools, id: \.id) { tool in
          metricPill(tool.value, tint: .toolMcp, monospaced: true)
        }
      }
    }
    .padding(.vertical, Spacing.xs)
  }

  private func collaborationModeRow(_ mode: ServerSessionCollaborationMode) -> some View {
    let isCurrent = currentCollaborationName == mode.name.lowercased()
    return VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(alignment: .top, spacing: Spacing.md) {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(collaborationDisplayName(for: mode))
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text(collaborationDescription(for: mode))
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 0)

        if isCurrent {
          metricPill("Current", tint: .feedbackPositive)
        } else {
          Button {
            Task { await model.applyCollaborationMode(mode, session: session) }
          } label: {
            if model.isApplyingCollaboration {
              ProgressView()
                .controlSize(.small)
            } else {
              Text("Apply")
            }
          }
          .buttonStyle(.borderedProminent)
          .tint(Color.accent)
          .disabled(model.isApplyingCollaboration || isAnyTurnActionRunning)
        }
      }

      HStack(spacing: Spacing.xs) {
        if let modeValue = mode.mode {
          metricPill(modeValue.capitalized, tint: .providerCodex)
        }
        if let modelValue = mode.model, !modelValue.isEmpty {
          metricPill(modelValue, tint: .statusReply, monospaced: true)
        }
        if let effort = mode.reasoningEffort, !effort.isEmpty {
          metricPill(effortLabel(effort), tint: .statusQuestion)
        } else if mode.clearsReasoningEffort {
          metricPill("Clears effort", tint: .feedbackCaution)
        }
      }
    }
    .padding(.vertical, Spacing.xs)
  }

  @ViewBuilder
  private func instructionBlock(title: String, value: String?) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(title)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textSecondary)

      if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(value)
          .font(.system(size: TypeScale.caption, design: .monospaced))
          .foregroundStyle(Color.textPrimary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(Spacing.sm)
          .background(Color.surfaceHover.opacity(0.55), in: RoundedRectangle(cornerRadius: Radius.md))
      } else {
        Text("Not set")
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
      }
    }
  }

  private func actionButton(
    title: String,
    running: Bool,
    tint: Color,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      if running {
        ProgressView()
          .controlSize(.small)
      } else {
        Text(title)
      }
    }
    .buttonStyle(.borderedProminent)
    .tint(tint)
  }

  private func runtimeValue(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(title)
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textQuaternary)
      Text(value)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textPrimary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func emptyState(
    title: String,
    message: String
  ) -> some View {
    card {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        Text(title)
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
        Text(message)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func card<Content: View>(
    title: String? = nil,
    detail: String? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if title != nil || detail != nil {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          if let title {
            Text(title)
              .font(.system(size: TypeScale.body, weight: .semibold))
              .foregroundStyle(Color.textPrimary)
          }
          if let detail, !detail.isEmpty {
            Text(detail)
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textTertiary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      content()
    }
    .padding(Spacing.md)
    .background(Color.backgroundTertiary)
    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }

  private func capabilityBadge(title: String, tint: Color) -> some View {
    Text(title)
      .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
      .foregroundStyle(tint)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(tint.opacity(0.16), in: Capsule())
  }

  private func metricPill(
    _ title: String,
    tint: Color,
    monospaced: Bool = false
  ) -> some View {
    Text(title)
      .font(
        .system(
          size: TypeScale.micro,
          weight: .semibold,
          design: monospaced ? .monospaced : .default
        )
      )
      .foregroundStyle(tint)
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, Spacing.xxs)
      .background(tint.opacity(0.14), in: Capsule())
  }

  private func horizontalPillRow<Data: RandomAccessCollection, ID: Hashable, Content: View>(
    _ items: Data,
    id: KeyPath<Data.Element, ID>,
    @ViewBuilder content: @escaping (Data.Element) -> Content
  ) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.xs) {
        ForEach(items, id: id) { item in
          content(item)
        }
      }
    }
    .scrollIndicators(.hidden)
  }

  private var runtimeColumns: [GridItem] {
    [
      GridItem(.flexible(minimum: 120), spacing: Spacing.md, alignment: .leading),
      GridItem(.flexible(minimum: 120), spacing: Spacing.md, alignment: .leading),
      GridItem(.flexible(minimum: 120), spacing: Spacing.md, alignment: .leading),
    ]
  }

  private var currentCollaborationName: String {
    model.sessionState?.collaborationMode?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? "default"
  }

  private var maxRollbackTurns: Int {
    max(1, Int(model.controls?.rollbackTurns.maxCount ?? 1))
  }

  private var canStopActiveTurn: Bool {
    model.controls?.stopActiveTurn.available ?? false
  }

  private var canCompactContext: Bool {
    model.controls?.compactContext.available ?? false
  }

  private var canUndoLastTurn: Bool {
    model.controls?.undoLastTurn.available ?? false
  }

  private var canRollbackTurns: Bool {
    model.controls?.rollbackTurns.available ?? false
  }

  private var supportsStopTarget: Bool {
    model.controls?.stopTarget.supported ?? false
  }

  private var supportsRewindToMessage: Bool {
    model.controls?.rewindToMessage.supported ?? false
  }

  private var stopTargetKindLabel: String {
    switch model.controls?.stopTarget.targetKind {
      case "task": return "Task"
      case let value?:
        return value.replacingOccurrences(of: "_", with: " ").capitalized
      case nil:
        return "Target"
    }
  }

  private var targetControlsDescription: String {
    if supportsStopTarget || supportsRewindToMessage {
      return "This provider exposes extra targeted controls beyond the shared stop, compact, undo, and rollback actions."
    }
    return "This provider currently exposes the shared session controls only. More granular target controls are not available here."
  }

  private var isAnyTurnActionRunning: Bool {
    model.isInterrupting || model.isCompacting || model.isUndoing || model.isRollingBack
  }

  private var workStatusLabel: String {
    switch model.sessionState?.workStatus {
      case .working: "Working"
      case .permission: "Waiting for approval"
      case .question: "Waiting for answer"
      case .reply: "Reply ready"
      case .waiting: "Waiting"
      case .ended: "Ended"
      case .none: "Idle"
    }
  }

  private var workStatusTint: Color {
    switch model.sessionState?.workStatus {
      case .working: .feedbackWarning
      case .permission, .question: .feedbackCaution
      case .reply: .feedbackPositive
      default: .textTertiary
    }
  }

  private var inputStateLabel: String {
    if model.sessionState?.steerable == true {
      return "Steerable"
    }
    if model.sessionState?.acceptsUserInput == true {
      return "Compose ready"
    }
    return "Input paused"
  }

  private func collaborationDisplayName(for mode: ServerSessionCollaborationMode) -> String {
    if let known = CodexCollaborationMode(rawValue: mode.name.lowercased()) {
      return known.displayName
    }
    return mode.name.capitalized
  }

  private func collaborationDescription(for mode: ServerSessionCollaborationMode) -> String {
    if let known = CodexCollaborationMode(rawValue: mode.name.lowercased()) {
      return known.description
    }
    return "Live collaboration preset reported by Codex for this session runtime."
  }

  private func effortLabel(_ value: String) -> String {
    switch value {
      case "none": "No effort"
      case "minimal": "Minimal"
      case "low": "Low"
      case "medium": "Medium"
      case "high": "High"
      case "xhigh": "XHigh"
      default: value.capitalized
    }
  }

  private func controlAvailabilityLabel(_ capability: ServerSessionControlCapability?) -> String {
    guard let capability else { return "Unknown" }
    if !capability.supported {
      return "Unsupported"
    }
    return capability.available ? "Available" : "Unavailable"
  }

  private func tabLabel(_ tab: SessionCapabilitiesModel.Tab) -> String {
    switch tab {
      case .runtime: "Runtime"
      case .plugins: "Plugins"
      case .skills: "Skills"
      case .mcp: "MCP"
    }
  }

  private func authLabel(_ status: ServerMcpAuthStatus?) -> String {
    switch status {
      case .unsupported: "Auth unsupported"
      case .notLoggedIn: "Needs auth"
      case .bearerToken: "Bearer token"
      case .oauth: "OAuth"
      case .none: "Auth unknown"
    }
  }

  private func accountSummary(_ account: ServerCodexAccount) -> String {
    switch account {
      case .apiKey:
        return "Connected with an API key. Plugin and MCP coverage may differ from ChatGPT-backed Codex."
      case let .chatgpt(email, planType):
        let plan = planType.map { " (\($0))" } ?? ""
        if let email, !email.isEmpty {
          return "Signed in with ChatGPT as \(email)\(plan)."
        }
        return "Signed in with ChatGPT\(plan)."
    }
  }
}

private extension ServerSkillScope {
  var label: String {
    switch self {
      case .repo: "Project"
      case .user: "User"
      case .system: "System"
      case .admin: "Admin"
    }
  }
}

private extension ServerPluginSummary {
  var installPolicyLabel: String {
    switch installPolicy {
      case .notAvailable: "Unavailable"
      case .available: "Available"
      case .installedByDefault: "Default"
    }
  }

  var authPolicyLabel: String {
    switch authPolicy {
      case .onInstall: "Auth on install"
      case .onUse: "Auth on use"
    }
  }
}
