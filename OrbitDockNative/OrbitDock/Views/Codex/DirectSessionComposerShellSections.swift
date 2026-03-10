import SwiftUI

struct DirectSessionComposerPromptSuggestions: View {
  let suggestions: [String]
  let onSelect: (String) -> Void
  @State private var hoveredSuggestion: String?

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.sm) {
        ForEach(suggestions, id: \.self) { suggestion in
          let isHovered = hoveredSuggestion == suggestion
          Button {
            onSelect(suggestion)
          } label: {
            Text(suggestion)
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(isHovered ? Color.textPrimary : Color.textSecondary)
              .lineLimit(1)
              .padding(.horizontal, Spacing.md_)
              .padding(.vertical, Spacing.sm_)
              .background(
                RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
                  .fill(isHovered ? Color.surfaceHover : Color.backgroundTertiary.opacity(0.5))
              )
              .overlay(
                RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
                  .strokeBorder(
                    isHovered
                      ? Color.accent.opacity(OpacityTier.light)
                      : Color.surfaceBorder.opacity(OpacityTier.subtle),
                    lineWidth: 1
                  )
              )
              .animation(Motion.hover, value: isHovered)
          }
          .buttonStyle(.plain)
          .onHover { hovering in
            hoveredSuggestion = hovering ? suggestion : nil
          }
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm_)
    }
  }
}

struct DirectSessionComposerResumeRow: View {
  let lastActivityAt: Date?
  let onResume: () -> Void

  var body: some View {
    HStack {
      Button(action: onResume) {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "arrow.counterclockwise")
          Text("Resume")
        }
      }
      .buttonStyle(GhostButtonStyle(color: .accent))

      Spacer()

      if let lastActivityAt {
        Text(lastActivityAt, style: .relative)
          .font(.system(size: TypeScale.body, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
  }
}

struct DirectSessionComposerErrorRow: View {
  let error: String
  let showsOpenSettingsAction: Bool
  let onOpenSettings: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.feedbackWarning)
      Text(error)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textSecondary)
      Spacer()
      if showsOpenSettingsAction {
        Button("Open Settings", action: onOpenSettings)
          .buttonStyle(GhostButtonStyle(color: .accent, size: .compact))
      }
      Button("Dismiss", action: onDismiss)
        .buttonStyle(GhostButtonStyle(color: .accent, size: .compact))
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.bottom, Spacing.sm)
  }
}
