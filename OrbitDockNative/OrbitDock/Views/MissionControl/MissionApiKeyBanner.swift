import SwiftUI

struct MissionApiKeyBanner: View {
  let missionId: String
  let http: ServerHTTPClient?
  let onKeySet: () async -> Void

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
          Text("Linear API Key Required")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.feedbackCaution)
        }

        Text(
          "A Linear API key is needed to poll for issues. Enter it below or set the LINEAR_API_KEY environment variable before starting the server."
        )
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

        Text("Stored encrypted on the server — never saved to MISSION.md or source control.")
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textQuaternary)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: Spacing.sm) {
          SecureField("lin_api_...", text: $apiKey)
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
        // or via the LINEAR_API_KEY environment variable.
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
      let _: LinearKeyResponse = try await http.post(
        "/api/server/linear-key",
        body: SetLinearKeyBody(key: apiKey)
      )
      apiKey = ""
      keySaved = true
      await onKeySet()
    } catch {
      self.error = "Failed to save key: \(error.localizedDescription)"
    }

    isSaving = false
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
