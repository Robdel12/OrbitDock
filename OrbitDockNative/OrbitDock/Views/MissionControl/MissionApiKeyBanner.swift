import SwiftUI

struct MissionApiKeyBanner: View {
  let missionId: String
  let trackerKind: String
  let http: ServerHTTPClient?
  let onKeySet: () async -> Void

  private var isGitHub: Bool {
    trackerKind == "github"
  }

  private var trackerLabel: String {
    isGitHub ? "GitHub Token" : "Linear API Key"
  }

  private var envVarName: String {
    isGitHub ? "GITHUB_TOKEN" : "LINEAR_API_KEY"
  }

  private var keyEndpoint: String {
    isGitHub ? "/api/server/github-key" : "/api/server/linear-key"
  }

  private var placeholder: String {
    isGitHub ? "ghp_..." : "lin_api_..."
  }

  @State private var apiKey = ""
  @State private var isSaving = false
  @State private var isStartingOrchestrator = false
  @State private var keySaved = false
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      if keySaved {
        // Key saved — guide to next step
        HStack(spacing: Spacing.sm) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(Color.feedbackPositive)
          Text("API Key Saved")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.feedbackPositive)
        }

        Text("Start the orchestrator to begin polling for issues.")
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)

        Button {
          Task { await startOrchestrator() }
        } label: {
          HStack(spacing: Spacing.sm) {
            if isStartingOrchestrator {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: "play.fill")
            }
            Text("Start Orchestrator")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(CosmicButtonStyle(color: .accent, size: .large))
        .disabled(isStartingOrchestrator)
      } else {
        // Key not saved — show input
        HStack(spacing: Spacing.sm) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(Color.feedbackCaution)
          Text("\(trackerLabel) Required")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.feedbackCaution)
        }

        Text(
          "A \(trackerLabel.lowercased()) is needed to poll for issues. Enter it below or set the \(envVarName) environment variable before starting the server."
        )
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

        Text("Stored encrypted on the server — never saved to mission file or source control.")
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textQuaternary)
          .fixedSize(horizontal: false, vertical: true)

        if isGitHub {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Required scopes for a classic token:")
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(Color.textTertiary)

            HStack(spacing: Spacing.sm) {
              tokenScopeBadge("repo")
              tokenScopeBadge("project")
              tokenScopeBadge("read:org")
            }

            Text("read:org is only needed if the project belongs to an organization.")
              .font(.system(size: TypeScale.micro))
              .foregroundStyle(Color.textQuaternary)
          }
        }

        HStack(spacing: Spacing.sm) {
          SecureField(placeholder, text: $apiKey)
            .textFieldStyle(.plain)
            .font(.system(size: TypeScale.caption, design: .monospaced))
            .padding(Spacing.sm)
            .background(
              RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(Color.backgroundTertiary)
            )

          Button {
            Task { await saveKey() }
          } label: {
            Group {
              if isSaving {
                ProgressView()
                  .controlSize(.small)
              } else {
                Text("Save")
                  .font(.system(size: TypeScale.caption, weight: .semibold))
              }
            }
            .foregroundStyle(apiKey.isEmpty ? Color.textTertiary : .white)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .background(
              RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(apiKey.isEmpty ? Color.backgroundTertiary : Color.accent)
            )
          }
          .buttonStyle(.plain)
          .disabled(apiKey.isEmpty || isSaving)
        }

        // API key can also be managed in app Settings > Mission Control,
        // or via the environment variable.
      }

      if let error {
        Text(error)
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.feedbackNegative)
      }
    }
    .statusBanner(color: keySaved ? Color.accent : Color.feedbackCaution)
  }

  private func saveKey() async {
    guard let http, !apiKey.isEmpty else { return }

    isSaving = true
    error = nil

    do {
      let _: TrackerKeyResponse = try await http.post(
        keyEndpoint,
        body: SetTrackerKeyBody(key: apiKey)
      )
      apiKey = ""
      keySaved = true
      await onKeySet()
    } catch {
      self.error = "Failed to save key: \(error.localizedDescription)"
    }

    isSaving = false
  }

  private func tokenScopeBadge(_ scope: String) -> some View {
    Text(scope)
      .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
      .foregroundStyle(Color.accent)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xxs)
      .background(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .fill(Color.accent.opacity(OpacityTier.light))
      )
  }

  private func startOrchestrator() async {
    guard let http else { return }
    isStartingOrchestrator = true
    error = nil

    do {
      let _: MissionOkResponse = try await http.post(
        "/api/missions/\(missionId)/start-orchestrator",
        body: EmptyBody()
      )
      await onKeySet()
    } catch {
      self.error = "Failed to start: \(error.localizedDescription)"
    }

    isStartingOrchestrator = false
  }
}
