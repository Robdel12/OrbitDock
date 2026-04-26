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
      List {
        WorkspaceHeaderSection(
          provider: provider,
          session: session,
          model: model,
          currentSection: model.selectedSection
        )

        Section {
          Picker("Workspace Section", selection: selectedSectionBinding) {
            ForEach(SessionCapabilitiesSection.allCases) { section in
              Text(section.title).tag(section)
            }
          }
          .pickerStyle(.segmented)
        }

        sectionContent
      }
      .modifier(CapabilitiesListStyleModifier())
      .scrollContentBackground(.hidden)
      .background(Color.backgroundPrimary)
      .navigationTitle("Codex Workspace")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            Task { await refreshSelectedSection() }
          } label: {
            if model.isLoading(model.selectedSection) {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: "arrow.clockwise")
            }
          }
          .help(model.selectedSection.refreshTitle)
          .disabled(model.isLoading(model.selectedSection))
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 620, minHeight: 560)
    #endif
    .task {
      model.syncSessionState(sessionState)
      model.setVisible(true, section: model.selectedSection)
      await loadSelectedSectionIfNeeded()
    }
    .onDisappear {
      model.setVisible(false, section: model.selectedSection)
    }
  }

  @ViewBuilder
  private var sectionContent: some View {
    switch model.selectedSection {
    case .skills:
      skillsContent
    case .plugins:
      pluginsContent
    case .mcp:
      mcpContent
    }
  }

  @ViewBuilder
  private var skillsContent: some View {
    let visibleEntries = model.skills.filter { !$0.skills.isEmpty || !$0.errors.isEmpty }

    if model.isLoading(.skills) && !model.hasLoaded(.skills) {
      loadingSection(message: "Loading skills…")
    }

    if !model.skillErrors.isEmpty {
      Section("Resolution Issues") {
        ForEach(Array(model.skillErrors.enumerated()), id: \.offset) { _, error in
          CapabilityIssueRow(
            title: error.path,
            message: error.message,
            tint: .feedbackCaution,
            monospacedTitle: true
          )
        }
      }
    }

    if visibleEntries.isEmpty, model.skillErrors.isEmpty, !model.isLoading(.skills) {
      emptyStateSection(
        title: SessionCapabilitiesSection.skills.emptyTitle,
        message: "This workspace does not currently expose any model-visible skills."
      )
    } else {
      ForEach(Array(visibleEntries.enumerated()), id: \.offset) { _, entry in
        Section {
          ForEach(entry.skills) { skill in
            SkillRow(skill: skill)
          }
        } header: {
          VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(entry.cwd)
            Text("\(entry.skills.count) skills")
          }
        }
      }
    }
  }

  @ViewBuilder
  private var pluginsContent: some View {
    if model.isLoading(.plugins) && !model.hasLoaded(.plugins) {
      loadingSection(message: "Loading plugins…")
    }

    if !model.pluginLoadErrors.isEmpty {
      Section("Marketplace Issues") {
        ForEach(model.pluginLoadErrors) { error in
          CapabilityIssueRow(
            title: error.marketplacePath,
            message: error.message,
            tint: .feedbackCaution,
            monospacedTitle: true
          )
        }
      }
    }

    if model.marketplaces.isEmpty, !model.isLoading(.plugins) {
      emptyStateSection(
        title: SessionCapabilitiesSection.plugins.emptyTitle,
        message: "Codex did not report any plugin catalogs for this workspace yet."
      )
    } else {
      ForEach(model.marketplaces) { marketplace in
        Section {
          ForEach(marketplace.plugins) { plugin in
            PluginRow(
              marketplace: marketplace,
              plugin: plugin,
              session: session,
              projectPath: projectPath,
              model: model
            )
          }
        } header: {
          VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(marketplace.interface?.displayName ?? marketplace.name)
            if let path = marketplace.path, !path.isEmpty {
              Text(path)
            } else {
              Text("Remote marketplace")
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var mcpContent: some View {
    if model.isLoading(.mcp) && !model.hasLoaded(.mcp) {
      loadingSection(message: "Loading MCP servers…")
    }

    Section {
      Button {
        Task { await model.refreshMcp(session: session, projectPath: projectPath) }
      } label: {
        if model.isLoading(.mcp) {
          Label("Refreshing servers...", systemImage: "arrow.triangle.2.circlepath")
        } else {
          Label("Refresh Servers", systemImage: "arrow.triangle.2.circlepath")
        }
      }
      .disabled(model.isLoading(.mcp))
    }

    if model.mcpServers.isEmpty, !model.isLoading(.mcp) {
      emptyStateSection(
        title: SessionCapabilitiesSection.mcp.emptyTitle,
        message: "If you expected one here, check your Codex config, account mode, and installed plugins."
      )
    } else {
      ForEach(model.mcpServers) { server in
        Section(server.name) {
          McpServerRow(
            server: server,
            session: session,
            projectPath: projectPath,
            model: model
          )
        }
      }
    }
  }

  private var selectedSectionBinding: Binding<SessionCapabilitiesSection> {
    Binding(
      get: { model.selectedSection },
      set: { newValue in
        let previous = model.selectedSection
        guard previous != newValue else { return }
        model.setVisible(false, section: previous)
        model.selectedSection = newValue
        model.setVisible(true, section: newValue)
        Task { await loadSelectedSectionIfNeeded() }
      }
    )
  }

  private func loadSelectedSectionIfNeeded() async {
    await model.loadIfNeeded(
      session: session,
      projectPath: projectPath,
      sessionState: sessionState,
      section: model.selectedSection
    )
  }

  private func refreshSelectedSection() async {
    switch model.selectedSection {
    case .mcp:
      await model.refreshMcp(session: session, projectPath: projectPath)
    case .skills:
      await model.refreshCurrentSection(
        session: session,
        projectPath: projectPath,
        sessionState: sessionState,
        forceReload: true
      )
    case .plugins:
      await model.refreshCurrentSection(
        session: session,
        projectPath: projectPath,
        sessionState: sessionState
      )
    }
  }

  private func loadingSection(message: String) -> some View {
    Section {
      HStack(spacing: Spacing.sm) {
        ProgressView()
          .controlSize(.small)
        Text(message)
          .foregroundStyle(Color.textSecondary)
      }
      .padding(.vertical, Spacing.xs)
    }
  }

  private func emptyStateSection(
    title: String,
    message: String
  ) -> some View {
    Section {
      CapabilityEmptyStateRow(title: title, message: message)
    }
  }
}

private struct WorkspaceHeaderSection: View {
  let provider: Provider
  let session: ServerSessionContext
  let model: SessionCapabilitiesModel
  let currentSection: SessionCapabilitiesSection

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        HStack(alignment: .center, spacing: Spacing.md) {
          VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text("Provider")
              .font(.system(size: TypeScale.micro, weight: .semibold))
              .foregroundStyle(Color.textQuaternary)
            Text(provider == .codex ? "Codex app server" : provider.rawValue.capitalized)
              .font(.system(size: TypeScale.body, weight: .semibold))
              .foregroundStyle(Color.textPrimary)
          }

          Spacer()

          StatusChip(
            title: statusTitle,
            tint: statusTint
          )
        }

        Text(
          "This workspace is driven by the live Codex session. Skills, plugins, and MCP load on demand and refresh only when that part of the workspace changes."
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

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: Spacing.xs) {
            StatusChip(
              title: model.hasLoaded(.skills) ? "\(skillCount) skills" : "Skills",
              tint: .statusQuestion
            )
            StatusChip(
              title: model.hasLoaded(.plugins) ? "\(pluginCount) plugins" : "Plugins",
              tint: .providerCodex
            )
            StatusChip(
              title: model.hasLoaded(.mcp) ? "\(model.mcpServers.count) MCP" : "MCP",
              tint: .toolMcp
            )
          }
        }
        .scrollIndicators(.hidden)

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
      .padding(.vertical, Spacing.xs)
    }
  }

  private var statusTitle: String {
    if model.isLoading(currentSection) {
      return "Refreshing"
    }
    return model.isStale(currentSection) ? "Needs Refresh" : "Ready"
  }

  private var statusTint: Color {
    if model.isLoading(currentSection) {
      return .providerCodex
    }
    return model.isStale(currentSection) ? .feedbackCaution : .feedbackPositive
  }

  private var pluginCount: Int {
    model.marketplaces.reduce(into: 0) { total, marketplace in
      total += marketplace.plugins.count
    }
  }

  private var skillCount: Int {
    model.skills.reduce(into: 0) { total, entry in
      total += entry.skills.count
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

private struct CapabilityIssueRow: View {
  let title: String
  let message: String
  let tint: Color
  let monospacedTitle: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(title)
        .font(.system(
          size: TypeScale.caption,
          weight: .semibold,
          design: monospacedTitle ? .monospaced : .default
        ))
        .foregroundStyle(Color.textPrimary)
        .lineLimit(1)
        .truncationMode(.middle)

      Text(message)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(tint)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, Spacing.xxs)
  }
}

private struct CapabilityEmptyStateRow: View {
  let title: String
  let message: String

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(title)
        .font(.system(size: TypeScale.body, weight: .semibold))
        .foregroundStyle(Color.textPrimary)
      Text(message)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, Spacing.xs)
  }
}

private struct SkillRow: View {
  let skill: ServerSkillMetadata

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
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

        VStack(alignment: .trailing, spacing: Spacing.xxs) {
          StatusChip(title: skill.scope.label, tint: .providerCodex)
          StatusChip(
            title: skill.enabled ? "Enabled" : "Disabled",
            tint: skill.enabled ? .feedbackPositive : .feedbackCaution
          )
        }
      }

      Text(skill.path)
        .font(.system(size: TypeScale.micro, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)

      if let tools = skill.dependencies?.tools, !tools.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: Spacing.xs) {
            ForEach(tools, id: \.id) { tool in
              StatusChip(title: tool.value, tint: .toolMcp, monospaced: true)
            }
          }
        }
        .scrollIndicators(.hidden)
      }
    }
    .padding(.vertical, Spacing.xxs)
  }
}

private struct PluginRow: View {
  let marketplace: ServerPluginMarketplaceEntry
  let plugin: ServerPluginSummary
  let session: ServerSessionContext
  let projectPath: String
  let model: SessionCapabilitiesModel

  var body: some View {
    let isInstalling = model.installingPluginIDs.contains(plugin.id)
    let isUninstalling = model.uninstallingPluginIDs.contains(plugin.id)

    VStack(alignment: .leading, spacing: Spacing.sm_) {
      HStack(alignment: .top, spacing: Spacing.md) {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(model.displayName(for: plugin))
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          if let shortDescription = plugin.interface?.shortDescription, !shortDescription.isEmpty {
            Text(shortDescription)
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          HStack(spacing: Spacing.xs) {
            StatusChip(title: plugin.installPolicyLabel, tint: .providerCodex)
            StatusChip(title: plugin.authPolicyLabel, tint: .providerCodex)
            if model.isFeatured(plugin) {
              StatusChip(title: "Featured", tint: .accent)
            }
            if plugin.installed {
              StatusChip(
                title: plugin.enabled ? "Installed" : "Disabled",
                tint: plugin.enabled ? .feedbackPositive : .feedbackCaution
              )
            }
          }
        }

        Spacer(minLength: 0)

        Button {
          Task {
            if plugin.installed {
              await model.uninstallPlugin(
                plugin: plugin,
                session: session,
                projectPath: projectPath
              )
            } else {
              await model.installPlugin(
                marketplace: marketplace,
                plugin: plugin,
                session: session,
                projectPath: projectPath
              )
            }
          }
        } label: {
          if isInstalling || isUninstalling {
            ProgressView()
              .controlSize(.small)
          } else {
            Text(plugin.installed ? "Uninstall" : "Install")
          }
        }
        .modifier(PluginActionButtonStyleModifier(installed: plugin.installed))
        .disabled(isInstalling || isUninstalling || plugin.installPolicy == .notAvailable)
        .tint(plugin.installed ? Color.textTertiary : Color.accent)
      }

      if let capabilities = plugin.interface?.capabilities, !capabilities.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: Spacing.xs) {
            ForEach(capabilities, id: \.self) { capability in
              StatusChip(title: capability, tint: .providerCodex)
            }
          }
        }
        .scrollIndicators(.hidden)
      }
    }
    .padding(.vertical, Spacing.xxs)
  }
}

private struct McpServerRow: View {
  let server: SessionCapabilitiesMcpServer
  let session: ServerSessionContext
  let projectPath: String
  let model: SessionCapabilitiesModel

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      HStack(alignment: .top, spacing: Spacing.md) {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          HStack(spacing: Spacing.xs) {
            StatusChip(title: authLabel(server.authStatus), tint: authTint(server.authStatus))
            StatusChip(title: "\(server.tools.count) tools", tint: .toolMcp)
          }

          if let message = authMessage(server.authStatus) {
            Text(message)
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        Spacer(minLength: 0)

        if canAuthenticate(server.authStatus) {
          Button {
            Task {
              await model.authenticateMcp(
                server: server,
                session: session,
                projectPath: projectPath
              )
            }
          } label: {
            if model.authenticatingMcpServerNames.contains(server.name) {
              ProgressView()
                .controlSize(.small)
            } else {
              Text("Sign In")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.authenticatingMcpServerNames.contains(server.name))
        }
      }

      if !server.tools.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text("Tools")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textSecondary)
          ForEach(server.tools.prefix(5), id: \.name) { tool in
            Text(tool.title ?? tool.name)
              .font(.system(size: TypeScale.caption, design: .monospaced))
              .foregroundStyle(Color.textTertiary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
      }

      if !server.resources.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text("Resources")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textSecondary)
          ForEach(server.resources.prefix(5), id: \.uri) { resource in
            Text(resource.title ?? resource.name)
              .font(.system(size: TypeScale.caption, design: .monospaced))
              .foregroundStyle(Color.textTertiary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
      }
    }
    .padding(.vertical, Spacing.xxs)
  }

  private func canAuthenticate(_ status: ServerMcpAuthStatus?) -> Bool {
    status == .notLoggedIn
  }

  private func authLabel(_ status: ServerMcpAuthStatus?) -> String {
    switch status {
    case .unsupported:
      "No auth action"
    case .notLoggedIn:
      "Sign-in needed"
    case .bearerToken:
      "Bearer token"
    case .oauth:
      "Signed in"
    case .none:
      "Auth unknown"
    }
  }

  private func authMessage(_ status: ServerMcpAuthStatus?) -> String? {
    switch status {
    case .unsupported:
      "This server does not expose an app-server OAuth flow."
    case .notLoggedIn:
      "Codex can open this server's OAuth sign-in flow."
    case .bearerToken:
      "This server is configured with a bearer token."
    case .oauth:
      "OAuth credentials are available to Codex."
    case .none:
      "Codex did not report an auth state for this server."
    }
  }

  private func authTint(_ status: ServerMcpAuthStatus?) -> Color {
    switch status {
    case .unsupported:
      .textTertiary
    case .notLoggedIn:
      .feedbackCaution
    case .bearerToken, .oauth:
      .feedbackPositive
    case .none:
      .textTertiary
    }
  }
}

private struct StatusChip: View {
  let title: String
  let tint: Color
  var monospaced = false

  var body: some View {
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
}

private struct CapabilitiesListStyleModifier: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
      content.listStyle(.insetGrouped)
    #else
      content.listStyle(.inset)
    #endif
  }
}

private struct PluginActionButtonStyleModifier: ViewModifier {
  let installed: Bool

  func body(content: Content) -> some View {
    if installed {
      content.buttonStyle(.bordered)
    } else {
      content.buttonStyle(.borderedProminent)
    }
  }
}

private extension ServerSkillScope {
  var label: String {
    switch self {
    case .repo:
      "Project"
    case .user:
      "User"
    case .system:
      "System"
    case .admin:
      "Admin"
    }
  }
}

private extension ServerPluginSummary {
  var installPolicyLabel: String {
    switch installPolicy {
    case .notAvailable:
      "Unavailable"
    case .available:
      "Available"
    case .installedByDefault:
      "Default"
    }
  }

  var authPolicyLabel: String {
    switch authPolicy {
    case .onInstall:
      "Auth on install"
    case .onUse:
      "Auth on use"
    }
  }
}
