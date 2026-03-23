import SwiftUI

struct NewMissionSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  let onCreated: (MissionSummary, UUID) -> Void

  @State private var missionName = ""
  @State private var selectedPath = ""
  @State private var selectedPathIsGit = false
  @State private var provider: SessionProvider = .claude
  @State private var trackerKind = "linear"
  @State private var isCreating = false
  @State private var error: String?
  @State private var selectedEndpointId: UUID?

  private var resolvedEndpointId: UUID {
    selectedEndpointId
      ?? runtimeRegistry.primaryEndpointId
      ?? runtimeRegistry.activeEndpointId
      ?? UUID()
  }

  private var missionsClient: MissionsClient? {
    runtimeRegistry.runtimesByEndpointId[resolvedEndpointId]?.clients.missions
  }

  private var canCreate: Bool {
    !missionName.isEmpty && !selectedPath.isEmpty && selectedPathIsGit && !isCreating && missionsClient != nil
  }

  private var availableEndpoints: [ServerRuntime] {
    runtimeRegistry.connectedRuntimes
  }

  var body: some View {
    NewSessionSheetShell(
      header: { header },
      formContent: { formContent },
      footer: { footer }
    )
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "antenna.radiowaves.left.and.right")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Color.accent)

      Text("New Mission")
        .font(.system(size: TypeScale.large, weight: .semibold))
        .foregroundStyle(Color.textPrimary)
        .lineLimit(1)

      Spacer()

      Button(action: { dismiss() }) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(Color.textTertiary)
          .frame(width: 24, height: 24)
          .background(Color.backgroundTertiary, in: Circle())
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.vertical, Spacing.lg)
  }

  // MARK: - Form

  private var formContent: some View {
    NewSessionFormShell {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        if availableEndpoints.count > 1 {
          endpointSection
        }

        nameSection

        directorySection

        if !selectedPath.isEmpty, !selectedPathIsGit {
          HStack(spacing: Spacing.sm_) {
            Image(systemName: "exclamationmark.triangle")
              .font(.system(size: IconScale.sm))
              .foregroundStyle(Color.feedbackCaution)
            Text("Selected directory is not a git repository")
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.feedbackCaution)
          }
        }

        providerSection

        trackerSection

        if let error {
          Text(error)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.statusError)
        }

        infoSection
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - Endpoint Section

  private var endpointSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Server")
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textPrimary)

      HStack(spacing: Spacing.sm) {
        ForEach(availableEndpoints, id: \.endpoint.id) { runtime in
          let isSelected = runtime.endpoint.id == resolvedEndpointId
          Button {
            selectedEndpointId = runtime.endpoint.id
            // Reset path when switching endpoints since repos differ per server
            selectedPath = ""
            selectedPathIsGit = false
          } label: {
            HStack(spacing: Spacing.sm_) {
              Image(systemName: "server.rack")
                .font(.system(size: IconScale.sm, weight: .semibold))
              Text(runtime.endpoint.name)
                .font(.system(size: TypeScale.caption, weight: .medium))
            }
            .foregroundStyle(isSelected ? Color.accent : Color.textSecondary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(
              RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(isSelected ? Color.accent.opacity(OpacityTier.light) : Color.backgroundTertiary)
                .overlay(
                  RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .strokeBorder(
                      isSelected ? Color.accent.opacity(OpacityTier.medium) : .clear,
                      lineWidth: 1
                    )
                )
            )
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var nameSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Mission Name")
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textPrimary)

      TextField("e.g. Bug Patrol, Feature Factory", text: $missionName)
        .textFieldStyle(.plain)
        .font(.system(size: TypeScale.body))
        .foregroundStyle(Color.textPrimary)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.md_)
        .background(
          RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(Color.backgroundTertiary)
            .overlay(
              RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(Color.surfaceBorder, lineWidth: 1)
            )
        )
    }
  }

  private var directorySection: some View {
    #if os(iOS)
      RemoteProjectPicker(
        selectedPath: $selectedPath,
        selectedPathIsGit: $selectedPathIsGit,
        endpointId: resolvedEndpointId
      )
    #else
      ProjectPicker(
        selectedPath: $selectedPath,
        selectedPathIsGit: $selectedPathIsGit,
        endpointId: resolvedEndpointId
      )
    #endif
  }

  private var providerSection: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      NewSessionProviderPicker(
        provider: provider,
        onSelect: { provider = $0 }
      )
    }
  }

  private var trackerSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Issue Tracker")
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textPrimary)

      HStack(spacing: Spacing.sm) {
        trackerOption("Linear", value: "linear", icon: "link", enabled: true)
        trackerOption("GitHub", value: "github", icon: "chevron.left.forwardslash.chevron.right", enabled: true)
      }
    }
  }

  private func trackerOption(_ label: String, value: String, icon: String, enabled: Bool) -> some View {
    Button {
      if enabled { trackerKind = value }
    } label: {
      HStack(spacing: Spacing.sm_) {
        Image(systemName: icon)
          .font(.system(size: IconScale.sm, weight: .semibold))
        Text(label)
          .font(.system(size: TypeScale.caption, weight: .medium))
        if !enabled {
          Text("Coming soon")
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textQuaternary)
        }
      }
      .foregroundStyle(enabled ? (trackerKind == value ? Color.accent : Color.textSecondary) : Color.textQuaternary)
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .background(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .fill(trackerKind == value && enabled ? Color.accent.opacity(OpacityTier.light) : Color.backgroundTertiary)
          .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              .strokeBorder(
                trackerKind == value && enabled ? Color.accent.opacity(OpacityTier.medium) : .clear,
                lineWidth: 1
              )
          )
      )
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
  }

  private var infoSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      Label("A mission file will be generated if not present", systemImage: "doc.text")
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textTertiary)

      Label(
        "Issues are pulled from \(trackerKind.capitalized) (configured in your mission file)",
        systemImage: "arrow.triangle.branch"
      )
      .font(.system(size: TypeScale.caption))
      .foregroundStyle(Color.textTertiary)
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: Spacing.sm) {
      #if os(iOS)
        cancelButton
          .frame(maxWidth: .infinity)
        createButton
          .frame(maxWidth: .infinity)
      #else
        Spacer()
        cancelButton
        createButton
      #endif
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.vertical, Spacing.lg)
  }

  private var cancelButton: some View {
    Button(action: { dismiss() }) {
      Text("Cancel")
      #if os(iOS)
        .frame(maxWidth: .infinity)
      #endif
    }
    .buttonStyle(GhostButtonStyle(color: .textSecondary, size: .large))
  }

  private var createButton: some View {
    Button {
      Task { await createMission() }
    } label: {
      Group {
        if isCreating {
          ProgressView()
            .controlSize(.small)
        } else {
          Text("Create Mission")
            .font(.system(size: TypeScale.body, weight: .semibold))
        }
      }
      .foregroundStyle(canCreate ? Color.white : Color.textTertiary)
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.md_)
      #if os(iOS)
        .frame(maxWidth: .infinity)
      #endif
        .background(
          RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(canCreate ? Color.accent : Color.backgroundTertiary)
        )
    }
    .buttonStyle(.plain)
    .disabled(!canCreate)
  }

  // MARK: - Actions

  private func createMission() async {
    guard let missionsClient else { return }
    isCreating = true
    error = nil

    let providerString = provider == .codex ? "codex" : "claude"

    do {
      let mission = try await missionsClient.createMission(
        name: missionName,
        repoRoot: selectedPath,
        trackerKind: trackerKind,
        provider: providerString
      )
      onCreated(mission, resolvedEndpointId)
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }

    isCreating = false
  }
}
