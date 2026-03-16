import SwiftUI

struct MissionApiKeyBanner: View {
  let missionId: String
  let http: ServerHTTPClient?
  let onKeySet: () async -> Void

  @State private var apiKey = ""
  @State private var isSaving = false
  @State private var error: String?

  #if os(macOS)
    @Environment(\.openSettings) private var openSettings
  #endif

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
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

      #if os(macOS)
        Button {
          openSettings()
        } label: {
          Label("Configure in Settings", systemImage: "gearshape")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.accent)
        }
        .buttonStyle(.plain)
      #endif

      if let error {
        Text(error)
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.feedbackNegative)
      }
    }
    .padding(Spacing.lg)
    .background(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(Color.feedbackCaution.opacity(OpacityTier.light))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
            .stroke(Color.feedbackCaution.opacity(OpacityTier.subtle), lineWidth: 1)
        )
    )
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
      await onKeySet()
    } catch {
      self.error = "Failed to save key: \(error.localizedDescription)"
    }

    isSaving = false
  }
}

private struct SetLinearKeyBody: Encodable {
  let key: String
}

private struct LinearKeyResponse: Decodable {
  let configured: Bool
}
