import SwiftUI

struct CodexConfigManagerSheet: View {
  enum SectionMode: String, CaseIterable, Identifiable {
    case profiles
    case providers

    var id: String {
      rawValue
    }
  }

  @Environment(\.dismiss) private var dismiss

  let cwd: String
  let fetchDocuments: @MainActor @Sendable (String) async throws -> SessionsClient.CodexConfigDocumentsResponse
  let batchWrite: @MainActor @Sendable (SessionsClient.CodexConfigBatchWriteRequest) async throws -> SessionsClient
    .CodexConfigWriteResponseData
  let onDidChange: @MainActor @Sendable () async -> Void

  @State private var mode: SectionMode = .profiles
  @State private var selectedScope: SessionsClient.CodexConfigDocumentScope = .user
  @State private var documents: SessionsClient.CodexConfigDocumentsResponse?
  @State private var isLoading = false
  @State private var errorMessage: String?
  @State private var saving = false
  @State private var saveMessage: String?

  @State private var selectedProfileName: String?
  @State private var profileDraft = CodexProfileDraft.empty

  @State private var selectedProviderID: String?
  @State private var providerDraft = CodexProviderDraft.empty

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          headerCard
          projectLayersCard
          modePicker

          if isLoading {
            ProgressView("Loading Codex config…")
              .controlSize(.regular)
          } else if let errorMessage {
            statusCard(title: "Couldn't load Codex config", message: errorMessage, tint: .feedbackNegative)
          } else {
            switch mode {
              case .profiles:
                profilesSection
              case .providers:
                providersSection
            }
          }
        }
        .padding(Spacing.lg)
      }
      .background(Color.backgroundPrimary)
      .navigationTitle("Manage Codex Config")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Refresh") {
            Task { await loadDocuments() }
          }
          .disabled(isLoading || saving)
        }
      }
    }
    .frame(minWidth: 760, minHeight: 640)
    .task {
      await loadDocuments()
    }
  }

  private var userDocument: SessionsClient.CodexConfigDocument? {
    documents?.user
  }

  private var projectDocuments: [SessionsClient.CodexConfigDocument] {
    documents?.projects ?? []
  }

  private var currentDocument: SessionsClient.CodexConfigDocument? {
    switch selectedScope {
      case .user:
        userDocument
      case .project:
        projectDocuments.first
    }
  }

  private var savedProfiles: [SessionsClient.CodexConfigProfileDocument] {
    currentDocument?.profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } ?? []
  }

  private var savedProviders: [SessionsClient.CodexProviderDocument] {
    currentDocument?.providers.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending } ?? []
  }

  private var currentScopeTitle: String {
    switch selectedScope {
      case .user:
        "User config"
      case .project:
        "Project config"
    }
  }

  private var currentScopeDescription: String {
    if selectedScope == .project {
      return "Profiles and providers saved here follow this workspace, which is helpful when a repo needs a shared provider setup."
    }
    return "Profiles and providers saved here are available everywhere Codex runs on this machine."
  }

  private var currentSelectionTitle: String {
    switch mode {
      case .profiles:
        selectedProfileName ?? "New profile"
      case .providers:
        selectedProviderID ?? "New provider"
    }
  }

  private var headerCard: some View {
    card {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        HStack(alignment: .top, spacing: Spacing.md) {
          VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text("Workspace")
              .font(.system(size: TypeScale.micro, weight: .semibold))
              .foregroundStyle(Color.textQuaternary)
            Text(cwd)
              .font(.system(size: TypeScale.caption, design: .monospaced))
              .foregroundStyle(Color.textTertiary)
              .lineLimit(2)
              .truncationMode(.middle)
              .textSelection(.enabled)
          }

          Spacer()

          statusPill(title: currentScopeTitle, tint: .accent)
        }

        Text("Manage the Codex profiles and provider definitions that OrbitDock can reuse across sessions.")
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
          .fixedSize(horizontal: false, vertical: true)

        Text(currentScopeDescription)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
          .fixedSize(horizontal: false, vertical: true)

        Picker("Scope", selection: $selectedScope) {
          Text("User config").tag(SessionsClient.CodexConfigDocumentScope.user)
          Text("Project config").tag(SessionsClient.CodexConfigDocumentScope.project)
        }
        .pickerStyle(.segmented)
        .disabled(projectDocuments.isEmpty)

        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: Spacing.md) {
            if let path = currentDocument?.filePath {
              metadataCard(title: "File", value: path, monospaced: true)
            }
            if let version = currentDocument?.version {
              metadataCard(title: "Version", value: version, monospaced: true)
            }
            metadataCard(title: "Writable", value: currentDocument?.writable == true ? "Yes" : "No")
          }

          VStack(alignment: .leading, spacing: Spacing.sm) {
            if let path = currentDocument?.filePath {
              metadataCard(title: "File", value: path, monospaced: true)
            }
            if let version = currentDocument?.version {
              metadataCard(title: "Version", value: version, monospaced: true)
            }
            metadataCard(title: "Writable", value: currentDocument?.writable == true ? "Yes" : "No")
          }
        }

        if selectedScope == .project, projectDocuments.isEmpty {
          Text(
            "No project `.codex/config.toml` applies to this folder yet. Save a user config entry first, or create a project config layer."
          )
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
        } else if let warning = currentDocument?.writeWarning, !warning.isEmpty {
          Text(warning)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.feedbackCaution)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text(
            selectedScope == .project
              ? "OrbitDock saves profiles and providers into the project-scoped Codex config that applies to this folder."
              : "OrbitDock saves profiles and providers into your user-scoped Codex config through Codex's own write APIs."
          )
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
        }

        if let saveMessage, !saveMessage.isEmpty {
          Text(saveMessage)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.feedbackPositive)
        }
      }
    }
  }

  @ViewBuilder
  private var projectLayersCard: some View {
    if !projectDocuments.isEmpty {
      card(
        title: "Project Layers",
        detail: "These `.codex` files affect the selected folder. OrbitDock writes into the nearest writable project layer Codex reports for this directory."
      ) {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          ForEach(Array(projectDocuments.enumerated()), id: \.offset) { index, document in
            VStack(alignment: .leading, spacing: Spacing.xxs) {
              HStack(spacing: Spacing.sm) {
                Text(document.filePath ?? "Unknown project config")
                  .font(.system(size: TypeScale.caption, weight: .semibold, design: .monospaced))
                  .foregroundStyle(Color.textPrimary)
                if selectedScope == .project, index == 0 {
                  Text("active")
                    .font(.system(size: TypeScale.micro, weight: .semibold))
                    .foregroundStyle(Color.accent)
                }
              }
              if let version = document.version {
                Text(version)
                  .font(.system(size: TypeScale.micro, design: .monospaced))
                  .foregroundStyle(Color.textQuaternary)
              }
            }
          }
        }
      }
    }
  }

  private var modePicker: some View {
    card {
      VStack(alignment: .leading, spacing: Spacing.md) {
        HStack(alignment: .center, spacing: Spacing.md) {
          VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text("Editor")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(Color.textSecondary)
            Text(
              mode == .profiles
                ? "Profiles package a provider and model into something you can pick quickly later."
                : "Providers define the API endpoint, auth key, and transport details Codex should use."
            )
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
          }

          Spacer(minLength: Spacing.md)

          statusPill(title: currentSelectionTitle, tint: mode == .profiles ? .providerCodex : .accent)
        }

        Picker("Section", selection: $mode) {
          Text("Profiles").tag(SectionMode.profiles)
          Text("Providers").tag(SectionMode.providers)
        }
        .pickerStyle(.segmented)
      }
    }
  }

  private var profilesSection: some View {
    splitEditorLayout(
      browser: {
        browserCard(
          title: "Saved Profiles",
          detail: selectedScope == .project
            ? "Project-scoped profiles are useful when a repository wants shared presets."
            : "Choose a saved Codex profile to edit, or create a fresh one.",
          buttonTitle: "New Profile",
          buttonAction: {
            selectedProfileName = nil
            profileDraft = .empty
            saveMessage = nil
          }
        ) {
          if savedProfiles.isEmpty {
            emptyBrowserState(
              title: selectedScope == .project ? "No project profiles yet" : "No saved profiles yet",
              detail: "Create a named setup so provider and model choices are easy to reuse."
            )
          } else {
            ForEach(savedProfiles) { profile in
              selectionRow(
                title: profile.name,
                detail: profileSummary(profile),
                isSelected: selectedProfileName == profile.name,
                action: {
                  selectedProfileName = profile.name
                  profileDraft = CodexProfileDraft(profile: profile)
                  saveMessage = nil
                }
              )
            }
          }
        }
      },
      editor: {
        card(
          title: selectedProfileName == nil ? "New Profile" : "Edit Profile",
          detail: "Profiles let Codex jump straight to a provider and model combination you use often."
        ) {
          VStack(alignment: .leading, spacing: Spacing.md) {
            labeledField("Profile name") {
              TextField("qwen", text: $profileDraft.name)
                .textFieldStyle(.roundedBorder)
            }

            labeledField("Model") {
              TextField("qwen/qwen3-coder-next", text: $profileDraft.model)
                .textFieldStyle(.roundedBorder)
            }

            labeledField("Provider") {
              TextField("openrouter", text: $profileDraft.modelProvider)
                .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: Spacing.sm) {
              Button(selectedProfileName == nil ? "Save Profile" : "Save Changes") {
                Task { await saveProfile() }
              }
              .buttonStyle(.borderedProminent)
              .disabled(saving || profileDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

              Button("Reset") {
                if let selected = savedProfiles.first(where: { $0.name == selectedProfileName }) {
                  profileDraft = CodexProfileDraft(profile: selected)
                } else {
                  profileDraft = .empty
                }
                saveMessage = nil
              }
              .buttonStyle(.bordered)
              .disabled(saving || currentDocument?.writable != true)

              if selectedProfileName != nil {
                Button("Delete Profile", role: .destructive) {
                  Task { await deleteProfile() }
                }
                .buttonStyle(.bordered)
                .disabled(saving || currentDocument?.writable != true)
              }
            }
          }
        }
      }
    )
  }

  private var providersSection: some View {
    splitEditorLayout(
      browser: {
        browserCard(
          title: "Saved Providers",
          detail: selectedScope == .project
            ? "Project-scoped providers are ideal when a repo depends on a shared gateway or local model endpoint."
            : "Provider definitions hold endpoint, auth, and transport details that Codex reuses.",
          buttonTitle: "New Provider",
          buttonAction: {
            selectedProviderID = nil
            providerDraft = .empty
            saveMessage = nil
          }
        ) {
          if savedProviders.isEmpty {
            emptyBrowserState(
              title: selectedScope == .project ? "No project providers yet" : "No custom providers yet",
              detail: "Add one when you want Codex to talk to OpenRouter, Ollama, LM Studio, or another compatible endpoint."
            )
          } else {
            ForEach(savedProviders) { provider in
              selectionRow(
                title: provider.displayName ?? provider.id,
                detail: providerSummary(provider),
                isSelected: selectedProviderID == provider.id,
                action: {
                  selectedProviderID = provider.id
                  providerDraft = CodexProviderDraft(provider: provider)
                  saveMessage = nil
                }
              )
            }
          }
        }
      },
      editor: {
        card(
          title: selectedProviderID == nil ? "New Provider" : "Edit Provider",
          detail: "Keep this focused on the things Codex needs to connect reliably. You can leave anything optional empty."
        ) {
          VStack(alignment: .leading, spacing: Spacing.md) {
            labeledField("Provider id") {
              TextField("openrouter", text: $providerDraft.id)
                .textFieldStyle(.roundedBorder)
            }

            labeledField("Display name") {
              TextField("OpenRouter", text: $providerDraft.name)
                .textFieldStyle(.roundedBorder)
            }

            labeledField("Base URL") {
              TextField("https://openrouter.ai/api/v1", text: $providerDraft.baseURL)
                .textFieldStyle(.roundedBorder)
            }

            labeledField("Env key") {
              TextField("OPENROUTER_API_KEY", text: $providerDraft.envKey)
                .textFieldStyle(.roundedBorder)
            }

            labeledField("Wire API") {
              TextField("responses", text: $providerDraft.wireAPI)
                .textFieldStyle(.roundedBorder)
            }

            labeledField("Env key instructions") {
              TextField("How users should set the env var", text: $providerDraft.envKeyInstructions, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            }

            labeledField("Bearer token override") {
              TextField("Optional token", text: $providerDraft.experimentalBearerToken)
                .textFieldStyle(.roundedBorder)
            }

            labeledField("Query params") {
              multilineKeyValueEditor(text: $providerDraft.queryParamsText, placeholder: "key=value")
            }

            labeledField("HTTP headers") {
              multilineKeyValueEditor(text: $providerDraft.httpHeadersText, placeholder: "Header=Value")
            }

            labeledField("Env HTTP headers") {
              multilineKeyValueEditor(text: $providerDraft.envHTTPHeadersText, placeholder: "Header=ENV_VAR")
            }

            HStack(spacing: Spacing.md) {
              labeledField("Request retries") {
                TextField("4", text: $providerDraft.requestMaxRetries)
                  .textFieldStyle(.roundedBorder)
                  .frame(width: 100)
              }

              labeledField("Stream retries") {
                TextField("5", text: $providerDraft.streamMaxRetries)
                  .textFieldStyle(.roundedBorder)
                  .frame(width: 100)
              }

              labeledField("Idle timeout ms") {
                TextField("300000", text: $providerDraft.streamIdleTimeoutMS)
                  .textFieldStyle(.roundedBorder)
                  .frame(width: 140)
              }
            }

            Toggle("Requires OpenAI auth", isOn: $providerDraft.requiresOpenAIAuth)
              .toggleStyle(.switch)

            Toggle("Supports websockets", isOn: $providerDraft.supportsWebsockets)
              .toggleStyle(.switch)

            HStack(spacing: Spacing.sm) {
              Button(selectedProviderID == nil ? "Save Provider" : "Save Changes") {
                Task { await saveProvider() }
              }
              .buttonStyle(.borderedProminent)
              .disabled(
                saving
                  || providerDraft.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  || providerDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  || currentDocument?.writable != true
              )

              Button("Reset") {
                if let selected = savedProviders.first(where: { $0.id == selectedProviderID }) {
                  providerDraft = CodexProviderDraft(provider: selected)
                } else {
                  providerDraft = .empty
                }
                saveMessage = nil
              }
              .buttonStyle(.bordered)
              .disabled(saving || currentDocument?.writable != true)

              if selectedProviderID != nil {
                Button("Delete Provider", role: .destructive) {
                  Task { await deleteProvider() }
                }
                .buttonStyle(.bordered)
                .disabled(saving || currentDocument?.writable != true)
              }
            }
          }
        }
      }
    )
  }

  private func loadDocuments() async {
    isLoading = true
    errorMessage = nil
    do {
      let response = try await fetchDocuments(cwd)
      documents = response
      isLoading = false

      if let selectedProfileName,
         let selected = currentProfiles(from: response).first(where: { $0.name == selectedProfileName })
      {
        profileDraft = CodexProfileDraft(profile: selected)
      }
      if let selectedProviderID,
         let selected = currentProviders(from: response).first(where: { $0.id == selectedProviderID })
      {
        providerDraft = CodexProviderDraft(provider: selected)
      }
    } catch {
      errorMessage = error.localizedDescription
      isLoading = false
    }
  }

  private func saveProfile() async {
    guard let currentDocument else { return }
    saving = true
    errorMessage = nil
    defer { saving = false }

    let newName = profileDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let payload: [String: Any] = [
      "model": normalizedOptional(profileDraft.model) as Any,
      "model_provider": normalizedOptional(profileDraft.modelProvider) as Any,
    ].compactMapValues { $0 }

    var edits = [
      SessionsClient.CodexConfigEditRequest(
        keyPath: "profiles.\(newName)",
        value: AnyCodable(payload),
        mergeStrategy: .replace
      ),
    ]

    if let selectedProfileName,
       selectedProfileName != newName,
       !selectedProfileName.isEmpty
    {
      edits.append(
        SessionsClient.CodexConfigEditRequest(
          keyPath: "profiles.\(selectedProfileName)",
          value: AnyCodable(NSNull()),
          mergeStrategy: .replace
        )
      )
    }

    do {
      _ = try await batchWrite(
        SessionsClient.CodexConfigBatchWriteRequest(
          cwd: cwd,
          edits: edits,
          filePath: currentDocument.filePath,
          expectedVersion: currentDocument.version
        )
      )
      selectedProfileName = newName
      saveMessage = "Saved profile \(newName)."
      await loadDocuments()
      await onDidChange()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func deleteProfile() async {
    guard let currentDocument, let selectedProfileName else { return }
    saving = true
    errorMessage = nil
    defer { saving = false }

    do {
      _ = try await batchWrite(
        SessionsClient.CodexConfigBatchWriteRequest(
          cwd: cwd,
          edits: [
            SessionsClient.CodexConfigEditRequest(
              keyPath: "profiles.\(selectedProfileName)",
              value: AnyCodable(NSNull()),
              mergeStrategy: .replace
            ),
          ],
          filePath: currentDocument.filePath,
          expectedVersion: currentDocument.version
        )
      )
      self.selectedProfileName = nil
      profileDraft = .empty
      saveMessage = "Deleted profile \(selectedProfileName)."
      await loadDocuments()
      await onDidChange()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func saveProvider() async {
    guard let currentDocument else { return }
    saving = true
    errorMessage = nil
    defer { saving = false }

    let newID = providerDraft.id.trimmingCharacters(in: .whitespacesAndNewlines)
    let payload = providerDraft.serializedConfig

    var edits = [
      SessionsClient.CodexConfigEditRequest(
        keyPath: "model_providers.\(newID)",
        value: AnyCodable(payload),
        mergeStrategy: .replace
      ),
    ]

    if let selectedProviderID,
       selectedProviderID != newID,
       !selectedProviderID.isEmpty
    {
      edits.append(
        SessionsClient.CodexConfigEditRequest(
          keyPath: "model_providers.\(selectedProviderID)",
          value: AnyCodable(NSNull()),
          mergeStrategy: .replace
        )
      )
    }

    do {
      _ = try await batchWrite(
        SessionsClient.CodexConfigBatchWriteRequest(
          cwd: cwd,
          edits: edits,
          filePath: currentDocument.filePath,
          expectedVersion: currentDocument.version
        )
      )
      selectedProviderID = newID
      saveMessage = "Saved provider \(newID)."
      await loadDocuments()
      await onDidChange()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func deleteProvider() async {
    guard let currentDocument, let selectedProviderID else { return }
    saving = true
    errorMessage = nil
    defer { saving = false }

    do {
      _ = try await batchWrite(
        SessionsClient.CodexConfigBatchWriteRequest(
          cwd: cwd,
          edits: [
            SessionsClient.CodexConfigEditRequest(
              keyPath: "model_providers.\(selectedProviderID)",
              value: AnyCodable(NSNull()),
              mergeStrategy: .replace
            ),
          ],
          filePath: currentDocument.filePath,
          expectedVersion: currentDocument.version
        )
      )
      self.selectedProviderID = nil
      providerDraft = .empty
      saveMessage = "Deleted provider \(selectedProviderID)."
      await loadDocuments()
      await onDidChange()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func card(
    title: String? = nil,
    detail: String? = nil,
    @ViewBuilder content: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if let title {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(title)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
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
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.lg)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }

  private func statusCard(title: String, message: String, tint: Color) -> some View {
    card(title: title) {
      Text(message)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(tint)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func infoRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
    HStack(alignment: .top) {
      Text(label)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textSecondary)
      Spacer()
      Text(value)
        .font(.system(size: TypeScale.caption, weight: .semibold, design: monospaced ? .monospaced : .default))
        .foregroundStyle(Color.textPrimary)
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
    }
  }

  private func splitEditorLayout(
    @ViewBuilder browser: () -> some View,
    @ViewBuilder editor: () -> some View
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: Spacing.lg) {
        browser()
          .frame(width: 292, alignment: .topLeading)
        editor()
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }

      VStack(alignment: .leading, spacing: Spacing.lg) {
        browser()
        editor()
      }
    }
  }

  private func browserCard(
    title: String,
    detail: String,
    buttonTitle: String,
    buttonAction: @escaping () -> Void,
    @ViewBuilder content: () -> some View
  ) -> some View {
    card(title: title, detail: detail) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        Button(buttonTitle, action: buttonAction)
          .buttonStyle(.bordered)
          .disabled(currentDocument?.writable != true)

        content()
      }
    }
  }

  private func selectionRow(
    title: String,
    detail: String,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(title)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
          Text(detail)
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: Spacing.sm)

        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(isSelected ? Color.accent : Color.textQuaternary)
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        isSelected ? Color.accent.opacity(0.12) : Color.backgroundSecondary,
        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .stroke(isSelected ? Color.accent.opacity(0.45) : Color.surfaceBorder, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }

  private func emptyBrowserState(title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(title)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textSecondary)
      Text(detail)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }

  private func metadataCard(title: String, value: String, monospaced: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(title)
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textQuaternary)
      Text(value)
        .font(.system(size: TypeScale.caption, weight: .semibold, design: monospaced ? .monospaced : .default))
        .foregroundStyle(Color.textPrimary)
        .lineLimit(3)
        .truncationMode(.middle)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.md)
    .background(Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }

  private func statusPill(title: String, tint: Color) -> some View {
    Text(title)
      .font(.system(size: TypeScale.micro, weight: .semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, 6)
      .background(tint.opacity(0.12), in: Capsule())
      .overlay(
        Capsule()
          .stroke(tint.opacity(0.25), lineWidth: 1)
      )
  }

  private func labeledField(_ label: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textSecondary)
      content()
    }
  }

  private func multilineKeyValueEditor(text: Binding<String>, placeholder: String) -> some View {
    TextField(placeholder, text: text, axis: .vertical)
      .textFieldStyle(.roundedBorder)
      .lineLimit(4 ... 8)
      .font(.system(size: TypeScale.caption, design: .monospaced))
  }

  private func profileSummary(_ profile: SessionsClient.CodexConfigProfileDocument) -> String {
    [profile.modelProvider.map { "Provider: \($0)" }, profile.model.map { "Model: \($0)" }]
      .compactMap { $0 }
      .joined(separator: " • ")
  }

  private func providerSummary(_ provider: SessionsClient.CodexProviderDocument) -> String {
    [
      provider.id,
      provider.baseURL,
      provider.envKey,
    ]
    .compactMap { $0 }
    .joined(separator: " • ")
  }

  private func normalizedOptional(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func currentProfiles(from response: SessionsClient
    .CodexConfigDocumentsResponse) -> [SessionsClient.CodexConfigProfileDocument]
  {
    switch selectedScope {
      case .user:
        response.user.profiles
      case .project:
        response.projects.first?.profiles ?? []
    }
  }

  private func currentProviders(from response: SessionsClient
    .CodexConfigDocumentsResponse) -> [SessionsClient.CodexProviderDocument]
  {
    switch selectedScope {
      case .user:
        response.user.providers
      case .project:
        response.projects.first?.providers ?? []
    }
  }
}

private struct CodexProfileDraft {
  var name: String
  var model: String
  var modelProvider: String

  static let empty = CodexProfileDraft(name: "", model: "", modelProvider: "")

  init(name: String, model: String, modelProvider: String) {
    self.name = name
    self.model = model
    self.modelProvider = modelProvider
  }

  init(profile: SessionsClient.CodexConfigProfileDocument) {
    self.name = profile.name
    self.model = profile.model ?? ""
    self.modelProvider = profile.modelProvider ?? ""
  }
}

private struct CodexProviderDraft {
  var id: String
  var name: String
  var baseURL: String
  var envKey: String
  var wireAPI: String
  var envKeyInstructions: String
  var experimentalBearerToken: String
  var queryParamsText: String
  var httpHeadersText: String
  var envHTTPHeadersText: String
  var requestMaxRetries: String
  var streamMaxRetries: String
  var streamIdleTimeoutMS: String
  var requiresOpenAIAuth: Bool
  var supportsWebsockets: Bool

  static let empty = CodexProviderDraft(
    id: "",
    name: "",
    baseURL: "",
    envKey: "",
    wireAPI: "responses",
    envKeyInstructions: "",
    experimentalBearerToken: "",
    queryParamsText: "",
    httpHeadersText: "",
    envHTTPHeadersText: "",
    requestMaxRetries: "",
    streamMaxRetries: "",
    streamIdleTimeoutMS: "",
    requiresOpenAIAuth: false,
    supportsWebsockets: false
  )

  init(
    id: String,
    name: String,
    baseURL: String,
    envKey: String,
    wireAPI: String,
    envKeyInstructions: String,
    experimentalBearerToken: String,
    queryParamsText: String,
    httpHeadersText: String,
    envHTTPHeadersText: String,
    requestMaxRetries: String,
    streamMaxRetries: String,
    streamIdleTimeoutMS: String,
    requiresOpenAIAuth: Bool,
    supportsWebsockets: Bool
  ) {
    self.id = id
    self.name = name
    self.baseURL = baseURL
    self.envKey = envKey
    self.wireAPI = wireAPI
    self.envKeyInstructions = envKeyInstructions
    self.experimentalBearerToken = experimentalBearerToken
    self.queryParamsText = queryParamsText
    self.httpHeadersText = httpHeadersText
    self.envHTTPHeadersText = envHTTPHeadersText
    self.requestMaxRetries = requestMaxRetries
    self.streamMaxRetries = streamMaxRetries
    self.streamIdleTimeoutMS = streamIdleTimeoutMS
    self.requiresOpenAIAuth = requiresOpenAIAuth
    self.supportsWebsockets = supportsWebsockets
  }

  init(provider: SessionsClient.CodexProviderDocument) {
    let config = (provider.config.value as? [String: Any]) ?? [:]
    self.id = provider.id
    self.name = (config["name"] as? String) ?? provider.displayName ?? provider.id
    self.baseURL = (config["base_url"] as? String) ?? provider.baseURL ?? ""
    self.envKey = (config["env_key"] as? String) ?? provider.envKey ?? ""
    self.wireAPI = (config["wire_api"] as? String) ?? provider.wireAPI ?? "responses"
    self.envKeyInstructions = (config["env_key_instructions"] as? String) ?? ""
    self.experimentalBearerToken = (config["experimental_bearer_token"] as? String) ?? ""
    self.queryParamsText = Self.mapText(config["query_params"] as? [String: Any])
    self.httpHeadersText = Self.mapText(config["http_headers"] as? [String: Any])
    self.envHTTPHeadersText = Self.mapText(config["env_http_headers"] as? [String: Any])
    self.requestMaxRetries = Self.numberText(config["request_max_retries"])
    self.streamMaxRetries = Self.numberText(config["stream_max_retries"])
    self.streamIdleTimeoutMS = Self.numberText(config["stream_idle_timeout_ms"])
    self.requiresOpenAIAuth = (config["requires_openai_auth"] as? Bool) ?? false
    self.supportsWebsockets = (config["supports_websockets"] as? Bool) ?? false
  }

  var serializedConfig: [String: Any] {
    var config: [String: Any] = [
      "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
      "wire_api": normalized(wireAPI) ?? "responses",
      "requires_openai_auth": requiresOpenAIAuth,
      "supports_websockets": supportsWebsockets,
    ]

    if let value = normalized(baseURL) { config["base_url"] = value }
    if let value = normalized(envKey) { config["env_key"] = value }
    if let value = normalized(envKeyInstructions) { config["env_key_instructions"] = value }
    if let value = normalized(experimentalBearerToken) { config["experimental_bearer_token"] = value }
    if let value = Self.keyValueMap(from: queryParamsText) { config["query_params"] = value }
    if let value = Self.keyValueMap(from: httpHeadersText) { config["http_headers"] = value }
    if let value = Self.keyValueMap(from: envHTTPHeadersText) { config["env_http_headers"] = value }
    if let value = UInt64(requestMaxRetries.trimmingCharacters(in: .whitespacesAndNewlines)) {
      config["request_max_retries"] = value
    }
    if let value = UInt64(streamMaxRetries.trimmingCharacters(in: .whitespacesAndNewlines)) {
      config["stream_max_retries"] = value
    }
    if let value = UInt64(streamIdleTimeoutMS.trimmingCharacters(in: .whitespacesAndNewlines)) {
      config["stream_idle_timeout_ms"] = value
    }

    return config
  }

  private func normalized(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func keyValueMap(from text: String) -> [String: String]? {
    let rows = text
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    guard !rows.isEmpty else { return nil }

    var map: [String: String] = [:]
    for row in rows {
      let parts = row.split(separator: "=", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { continue }
      let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
      let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty, !value.isEmpty else { continue }
      map[key] = value
    }
    return map.isEmpty ? nil : map
  }

  private static func mapText(_ map: [String: Any]?) -> String {
    guard let map else { return "" }
    return map
      .compactMap { key, value -> String? in
        guard let value = value as? String else { return nil }
        return "\(key)=\(value)"
      }
      .sorted()
      .joined(separator: "\n")
  }

  private static func numberText(_ value: Any?) -> String {
    if let value = value as? NSNumber {
      return value.stringValue
    }
    if let value = value as? Int {
      return String(value)
    }
    if let value = value as? UInt64 {
      return String(value)
    }
    return ""
  }
}
