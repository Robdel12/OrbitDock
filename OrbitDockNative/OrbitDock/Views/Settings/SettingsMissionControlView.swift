import SwiftUI

struct SettingsMissionControlView: View {
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  @State private var linearKeyConfigured = false
  @State private var linearKeySource: String?
  @State private var linearApiKey = ""
  @State private var isSavingKey = false
  @State private var isDeletingKey = false
  @State private var keyError: String?

  @State private var defaultStrategy = "single"
  @State private var defaultPrimary = "claude"
  @State private var defaultSecondary = ""
  @State private var isSavingDefaults = false

  @State private var isLoading = true

  private var http: ServerHTTPClient? {
    runtimeRegistry.primaryRuntime?.clients.http ?? runtimeRegistry.activeRuntime?.clients.http
  }

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        trackerKeysSection
        defaultProviderSection
      }
      .padding(Spacing.xl)
    }
    .task { await loadState() }
  }

  // MARK: - Tracker API Keys

  private var trackerKeysSection: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      sectionHeader("Tracker API Keys", icon: "key")

      // Linear
      VStack(alignment: .leading, spacing: Spacing.md) {
        HStack(spacing: Spacing.sm) {
          Text("Linear")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Spacer()

          if linearKeyConfigured {
            HStack(spacing: Spacing.xs) {
              Circle()
                .fill(Color.feedbackPositive)
                .frame(width: 6, height: 6)
              Text(linearKeySource == "env" ? "Environment variable" : "Saved in settings")
                .font(.system(size: TypeScale.micro, weight: .medium))
                .foregroundStyle(Color.feedbackPositive)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Color.feedbackPositive.opacity(OpacityTier.subtle), in: Capsule())
          } else {
            HStack(spacing: Spacing.xs) {
              Circle()
                .fill(Color.feedbackCaution)
                .frame(width: 6, height: 6)
              Text("Not configured")
                .font(.system(size: TypeScale.micro, weight: .medium))
                .foregroundStyle(Color.feedbackCaution)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Color.feedbackCaution.opacity(OpacityTier.subtle), in: Capsule())
          }
        }

        HStack(spacing: Spacing.sm) {
          SecureField("lin_api_...", text: $linearApiKey)
            .textFieldStyle(.plain)
            .font(.system(size: TypeScale.caption, design: .monospaced))
            .padding(Spacing.sm)
            .background(
              RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(Color.backgroundTertiary)
            )

          Button {
            Task { await saveLinearKey() }
          } label: {
            Group {
              if isSavingKey {
                ProgressView()
                  .controlSize(.mini)
              } else {
                Text("Save")
                  .font(.system(size: TypeScale.caption, weight: .semibold))
              }
            }
            .foregroundStyle(linearApiKey.isEmpty ? Color.textTertiary : .white)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(
              RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(linearApiKey.isEmpty ? Color.backgroundTertiary : Color.accent)
            )
          }
          .buttonStyle(.plain)
          .disabled(linearApiKey.isEmpty || isSavingKey)

          if linearKeyConfigured {
            Button {
              Task { await deleteLinearKey() }
            } label: {
              Group {
                if isDeletingKey {
                  ProgressView()
                    .controlSize(.mini)
                } else {
                  Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                }
              }
              .foregroundStyle(Color.feedbackNegative)
              .padding(.horizontal, Spacing.sm)
              .padding(.vertical, Spacing.sm)
              .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                  .fill(Color.feedbackNegative.opacity(OpacityTier.subtle))
              )
            }
            .buttonStyle(.plain)
            .disabled(isDeletingKey)
          }
        }

        if let keyError {
          Text(keyError)
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.feedbackNegative)
        }
      }

      Divider().foregroundStyle(Color.surfaceBorder)

      // GitHub
      HStack(spacing: Spacing.sm) {
        Text("GitHub")
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(Color.textQuaternary)

        Spacer()

        Text("Coming soon")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)
          .background(Color.backgroundTertiary, in: Capsule())
      }
    }
    .padding(Spacing.lg)
    .background(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(Color.backgroundSecondary)
        .overlay(
          RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
            .strokeBorder(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
        )
    )
  }

  // MARK: - Default Provider

  private var defaultProviderSection: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      sectionHeader("Default Provider", icon: "cpu")

      Text("Defaults for newly created missions. Existing missions keep their own settings.")
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textTertiary)

      // Strategy
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Strategy")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textTertiary)

        HStack(spacing: Spacing.sm) {
          providerOption("Single", value: "single", selected: defaultStrategy) { defaultStrategy = "single" }
          providerOption("Priority", value: "priority", selected: defaultStrategy) { defaultStrategy = "priority" }
          providerOption("Round Robin", value: "round_robin", selected: defaultStrategy) {
            defaultStrategy = "round_robin"
          }
        }
      }

      // Primary
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Primary Provider")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textTertiary)

        HStack(spacing: Spacing.sm) {
          providerOption("Claude", value: "claude", selected: defaultPrimary) { defaultPrimary = "claude" }
          providerOption("Codex", value: "codex", selected: defaultPrimary) { defaultPrimary = "codex" }
        }
      }

      // Secondary (shown for priority / round-robin)
      if defaultStrategy != "single" {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Secondary Provider")
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textTertiary)

          HStack(spacing: Spacing.sm) {
            providerOption("Claude", value: "claude", selected: defaultSecondary) { defaultSecondary = "claude" }
            providerOption("Codex", value: "codex", selected: defaultSecondary) { defaultSecondary = "codex" }
            providerOption("None", value: "", selected: defaultSecondary) { defaultSecondary = "" }
          }
        }
      }

      // Save
      HStack {
        Spacer()
        Button {
          Task { await saveDefaults() }
        } label: {
          Group {
            if isSavingDefaults {
              ProgressView()
                .controlSize(.mini)
            } else {
              Text("Save Defaults")
                .font(.system(size: TypeScale.caption, weight: .semibold))
            }
          }
          .foregroundStyle(.white)
          .padding(.horizontal, Spacing.lg)
          .padding(.vertical, Spacing.sm)
          .background(Color.accent, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isSavingDefaults)
      }
    }
    .padding(Spacing.lg)
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

  private func sectionHeader(_ title: String, icon: String) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: icon)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.accent)
      Text(title)
        .font(.system(size: TypeScale.large, weight: .semibold))
        .foregroundStyle(Color.textPrimary)
    }
  }

  private func providerOption(
    _ label: String,
    value: String,
    selected: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(label)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(selected == value ? Color.accent : Color.textSecondary)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
          RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(selected == value ? Color.accent.opacity(OpacityTier.light) : Color.backgroundTertiary)
            .overlay(
              RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(selected == value ? Color.accent.opacity(OpacityTier.medium) : .clear, lineWidth: 1)
            )
        )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Networking

  private func loadState() async {
    guard let http else {
      isLoading = false
      return
    }

    isLoading = true

    // Load tracker keys
    do {
      let keys: TrackerKeysResponse = try await http.get("/api/server/tracker-keys")
      linearKeyConfigured = keys.linear.configured
      linearKeySource = keys.linear.source
    } catch {
      // Fallback — try old endpoint
      if let status: LinearKeyStatus = try? await http.get("/api/server/linear-key") {
        linearKeyConfigured = status.configured
      }
    }

    // Load defaults
    if let defaults: MissionDefaultsResponse = try? await http.get("/api/server/mission-defaults") {
      defaultStrategy = defaults.providerStrategy
      defaultPrimary = defaults.primaryProvider
      defaultSecondary = defaults.secondaryProvider ?? ""
    }

    isLoading = false
  }

  private func saveLinearKey() async {
    guard let http, !linearApiKey.isEmpty else { return }
    isSavingKey = true
    keyError = nil

    do {
      let _: LinearKeyStatus = try await http.post(
        "/api/server/linear-key",
        body: SetKeyBody(key: linearApiKey)
      )
      linearApiKey = ""
      linearKeyConfigured = true
      linearKeySource = "settings"
    } catch {
      keyError = "Failed: \(error.localizedDescription)"
    }

    isSavingKey = false
  }

  private func deleteLinearKey() async {
    guard let http else { return }
    isDeletingKey = true

    do {
      let _: LinearKeyStatus = try await http.request(
        path: "/api/server/linear-key",
        method: "DELETE"
      )
      linearKeyConfigured = false
      linearKeySource = nil
    } catch {
      keyError = "Failed: \(error.localizedDescription)"
    }

    isDeletingKey = false
  }

  private func saveDefaults() async {
    guard let http else { return }
    isSavingDefaults = true

    let body = UpdateDefaultsBody(
      providerStrategy: defaultStrategy,
      primaryProvider: defaultPrimary,
      secondaryProvider: defaultSecondary.isEmpty ? nil : defaultSecondary
    )

    let _: MissionDefaultsResponse? = try? await http.request(
      path: "/api/server/mission-defaults",
      method: "PUT",
      body: body
    )

    isSavingDefaults = false
  }
}

// MARK: - Network Types

private struct TrackerKeysResponse: Decodable {
  let linear: TrackerKeyInfoResponse
  let github: TrackerKeyInfoResponse
}

private struct TrackerKeyInfoResponse: Decodable {
  let configured: Bool
  let source: String?
}

private struct LinearKeyStatus: Decodable {
  let configured: Bool
}

private struct SetKeyBody: Encodable {
  let key: String
}

private struct MissionDefaultsResponse: Codable {
  let providerStrategy: String
  let primaryProvider: String
  let secondaryProvider: String?

  enum CodingKeys: String, CodingKey {
    case providerStrategy = "provider_strategy"
    case primaryProvider = "primary_provider"
    case secondaryProvider = "secondary_provider"
  }
}

private struct UpdateDefaultsBody: Encodable {
  let providerStrategy: String
  let primaryProvider: String
  let secondaryProvider: String?

  enum CodingKeys: String, CodingKey {
    case providerStrategy = "provider_strategy"
    case primaryProvider = "primary_provider"
    case secondaryProvider = "secondary_provider"
  }
}
