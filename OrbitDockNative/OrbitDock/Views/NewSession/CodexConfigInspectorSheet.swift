import SwiftUI

struct CodexConfigInspectorSheet: View {
  @Environment(\.dismiss) private var dismiss

  let response: SessionsClient.CodexInspectorResponse?
  let errorMessage: String?
  let isLoading: Bool
  let onRefresh: () -> Void

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          if isLoading {
            ProgressView("Inspecting Codex config...")
              .controlSize(.regular)
          } else if let errorMessage {
            inspectorCard(title: "Couldn't load config") {
              Text(errorMessage)
                .foregroundStyle(Color.textTertiary)
            }
          } else if let response {
            effectiveSettingsSection(response)

            if !response.warnings.isEmpty {
              warningsSection(response.warnings)
            }

            originsSection(response.origins)
            layersSection(response.layers)
          } else {
            inspectorCard(title: "No data yet") {
              Text("Run the inspector to see the effective Codex settings and where each value comes from.")
                .foregroundStyle(Color.textTertiary)
            }
          }
        }
        .padding(Spacing.lg)
      }
      .background(Color.backgroundPrimary)
      .navigationTitle("Codex Config")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") {
            dismiss()
          }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Refresh") {
            onRefresh()
          }
          .disabled(isLoading)
        }
      }
    }
    .frame(minWidth: 640, minHeight: 560)
  }

  private func effectiveSettingsSection(_ response: SessionsClient.CodexInspectorResponse) -> some View {
    inspectorCard(title: "Effective Settings") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        settingRow("Model", value: response.effectiveSettings.model)
        settingRow("Approval", value: response.effectiveSettings.approvalPolicy)
        settingRow("Sandbox", value: response.effectiveSettings.sandboxMode)
        settingRow("Collaboration", value: response.effectiveSettings.collaborationMode)
        settingRow("Workers", value: response.effectiveSettings.multiAgent.map { $0 ? "Enabled" : "Disabled" })
        settingRow("Personality", value: response.effectiveSettings.personality)
        settingRow("Service Tier", value: response.effectiveSettings.serviceTier)
        settingRow("Instructions", value: trimmedValue(response.effectiveSettings.developerInstructions))
        settingRow("Effort", value: response.effectiveSettings.effort)
      }
    }
  }

  private func warningsSection(_ warnings: [String]) -> some View {
    inspectorCard(title: "Warnings") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        ForEach(warnings, id: \.self) { warning in
          Text(warning)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.feedbackCaution)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private func originsSection(_ origins: [String: SessionsClient.CodexInspectorOrigin]) -> some View {
    inspectorCard(title: "Origins") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        ForEach(origins.keys.sorted(), id: \.self) { key in
          if let origin = origins[key] {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
              HStack {
                Text(key)
                  .font(.system(size: TypeScale.caption, weight: .semibold, design: .monospaced))
                  .foregroundStyle(Color.textPrimary)
                Spacer()
                Text(origin.sourceKind)
                  .font(.system(size: TypeScale.micro, weight: .semibold))
                  .foregroundStyle(Color.providerCodex)
              }
              Text(origin.path ?? origin.version)
                .font(.system(size: TypeScale.micro, design: .monospaced))
                .foregroundStyle(Color.textQuaternary)
                .textSelection(.enabled)
            }
            .padding(.bottom, Spacing.xs)
          }
        }
      }
    }
  }

  private func layersSection(_ layers: [SessionsClient.CodexInspectorLayer]) -> some View {
    inspectorCard(title: "Layer Stack") {
      VStack(alignment: .leading, spacing: Spacing.md) {
        ForEach(layers) { layer in
          VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 2) {
                Text(layer.sourceKind)
                  .font(.system(size: TypeScale.caption, weight: .semibold))
                  .foregroundStyle(Color.textPrimary)
                Text(layer.path ?? layer.version)
                  .font(.system(size: TypeScale.micro, design: .monospaced))
                  .foregroundStyle(Color.textQuaternary)
                  .textSelection(.enabled)
              }

              Spacer()

              if let disabledReason = layer.disabledReason {
                Text(disabledReason)
                  .font(.system(size: TypeScale.micro, weight: .semibold))
                  .foregroundStyle(Color.feedbackCaution)
              }
            }

            if let config = layer.config.jsonString {
              ScrollView(.horizontal, showsIndicators: false) {
                Text(config)
                  .font(.system(size: TypeScale.micro, design: .monospaced))
                  .foregroundStyle(Color.textSecondary)
                  .textSelection(.enabled)
                  .padding(Spacing.sm)
              }
              .background(Color.backgroundPrimary, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            }
          }
          .padding(Spacing.md)
          .background(Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
              .stroke(Color.surfaceBorder, lineWidth: 1)
          )
        }
      }
    }
  }

  private func inspectorCard(title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text(title)
        .font(.system(size: TypeScale.body, weight: .semibold))
        .foregroundStyle(Color.textPrimary)
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

  private func settingRow(_ label: String, value: String?) -> some View {
    HStack(alignment: .top) {
      Text(label)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textSecondary)
      Spacer()
      Text(value ?? "Inherited")
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(value == nil ? Color.textQuaternary : Color.textPrimary)
        .multilineTextAlignment(.trailing)
    }
  }

  private func trimmedValue(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
