import SwiftUI

struct ClaudeHooksSetupPane: View {
  @Bindable var model: SetupSettingsModel

  var body: some View {
    SettingsSection(title: "CLAUDE CODE", icon: "terminal") {
      VStack(alignment: .leading, spacing: Spacing.lg_) {
        HStack {
          statusContent
          Spacer()
        }

        Divider()
          .foregroundStyle(Color.panelBorder)

        VStack(alignment: .leading, spacing: Spacing.sm) {
          Text("Add hooks to ~/.claude/settings.json:")
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textSecondary)

          HStack(spacing: Spacing.md_) {
            Button {
              model.copyHooksConfiguration()
            } label: {
              HStack(spacing: Spacing.sm_) {
                Image(systemName: model.copied ? "checkmark" : "doc.on.doc")
                  .font(.system(size: TypeScale.caption, weight: .medium))
                Text(model.copied ? "Copied!" : "Copy Hook Config")
                  .font(.system(size: TypeScale.caption, weight: .medium))
              }
              .foregroundStyle(model.copied ? Color.feedbackPositive : .primary)
              .padding(.horizontal, Spacing.lg_)
              .padding(.vertical, Spacing.sm)
              .background(Color.accent.opacity(model.copied ? 0.2 : 1), in: RoundedRectangle(cornerRadius: Radius.md))
              .foregroundStyle(model.copied ? Color.feedbackPositive : Color.backgroundPrimary)
            }
            .buttonStyle(.plain)

            Button {
              model.openSettingsFile()
            } label: {
              HStack(spacing: Spacing.sm_) {
                Image(systemName: "arrow.up.forward.square")
                  .font(.system(size: TypeScale.meta, weight: .medium))
                Text("Open File")
                  .font(.system(size: TypeScale.caption, weight: .medium))
              }
              .foregroundStyle(Color.accent)
              .padding(.horizontal, Spacing.md)
              .padding(.vertical, Spacing.sm)
              .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.md))
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
              model.refreshHooksConfiguration()
            } label: {
              Image(systemName: "arrow.clockwise")
                .font(.system(size: TypeScale.meta, weight: .medium))
                .foregroundStyle(Color.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Check configuration")
          }
        }
      }
    }
  }

  @ViewBuilder
  private var statusContent: some View {
    if let configured = model.hooksConfigured {
      Image(systemName: configured ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        .foregroundStyle(configured ? Color.feedbackPositive : Color.statusPermission)
      Text(configured ? "Hooks configured" : "Hooks not configured")
        .font(.system(size: TypeScale.body))
    } else {
      ProgressView()
        .controlSize(.small)
      Text("Checking...")
        .font(.system(size: TypeScale.body))
        .foregroundStyle(Color.textSecondary)
    }
  }
}
