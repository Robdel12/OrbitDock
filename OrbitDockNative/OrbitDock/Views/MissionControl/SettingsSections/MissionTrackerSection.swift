import SwiftUI

struct MissionTrackerSection: View {
  @Binding var trackerKeyConfigured: Bool
  @Binding var trackerKeySource: String?
  @Binding var newApiKey: String
  @Binding var isSavingKey: Bool
  @Binding var keyError: String?
  let trackerKind: String
  let http: ServerHTTPClient?
  let onUpdated: () async -> Void

  private var isGitHub: Bool {
    trackerKind == "github"
  }

  private var trackerLabel: String {
    isGitHub ? "GitHub token" : "Linear API key"
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

  var body: some View {
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
            Text("\(trackerLabel) configured")
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.textPrimary)

            if let source = trackerKeySource {
              Text("Source: \(source == "env" ? "\(envVarName) environment variable" : "saved in OrbitDock")")
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
          Text("\(trackerLabel) required to poll for issues")
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textSecondary)
        }

        HStack(spacing: Spacing.sm) {
          SecureField(placeholder, text: $newApiKey)
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

  private func saveTrackerKey() async {
    guard let http, !newApiKey.isEmpty else { return }
    isSavingKey = true
    keyError = nil
    do {
      let _: TrackerKeyResponse = try await http.post(
        keyEndpoint,
        body: SetTrackerKeyBody(key: newApiKey)
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
      let _: TrackerKeyResponse = try await http.request(
        path: keyEndpoint,
        method: "DELETE"
      )
      trackerKeyConfigured = false
      trackerKeySource = nil
      await onUpdated()
    } catch {
      keyError = "Failed to remove: \(error.localizedDescription)"
    }
  }
}
