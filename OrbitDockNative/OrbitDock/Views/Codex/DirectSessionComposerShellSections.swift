import SwiftUI

struct DirectSessionComposerShell<Leading: View, ActiveSurface: View, Resume: View, ErrorRow: View>: View {
  let isSessionActive: Bool
  let isCompactLayout: Bool
  let hasError: Bool
  @ViewBuilder let leading: () -> Leading
  @ViewBuilder let activeSurface: () -> ActiveSurface
  @ViewBuilder let resume: () -> Resume
  @ViewBuilder let errorRow: () -> ErrorRow

  var body: some View {
    VStack(spacing: 0) {
      leading()

      if isSessionActive {
        activeSurface()
      } else {
        resume()
      }

      if hasError {
        errorRow()
      }
    }
    .background(isCompactLayout ? Color.backgroundSecondary : Color.clear)
  }
}

struct DirectSessionComposerSurface<TopSections: View, Input: View, Footer: View, BottomSections: View, DropOverlay: View>:
  View
{
  let composerBorderColor: Color
  let inputMode: InputMode
  let pendingApprovalIdentity: String
  let pendingPanelExpanded: Bool
  let permissionPanelExpanded: Bool
  let isFocused: Bool
  let isDropTargeted: Bool
  let isCompactLayout: Bool
  let idleBorderOpacity: Double
  @ViewBuilder let topSections: () -> TopSections
  @ViewBuilder let input: () -> Input
  @ViewBuilder let footer: () -> Footer
  @ViewBuilder let bottomSections: () -> BottomSections
  @ViewBuilder let dropOverlay: () -> DropOverlay

  var body: some View {
    VStack(spacing: 0) {
      topSections()
      input()
      footer()
      bottomSections()
    }
    .background(surfaceBackground)
    .overlay(surfaceBorder)
    .overlay(dropOverlay())
    .animation(Motion.gentle, value: inputMode)
    .animation(Motion.standard, value: pendingApprovalIdentity)
    .animation(Motion.standard, value: pendingPanelExpanded)
    .animation(Motion.standard, value: permissionPanelExpanded)
    .animation(Motion.hover, value: isFocused)
    .animation(Motion.standard, value: isDropTargeted)
    .padding(.horizontal, isCompactLayout ? Spacing.md : Spacing.lg)
    .padding(.vertical, Spacing.sm)
  }

  var surfaceBackground: some View {
    RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
      .fill(
        isCompactLayout
          ? composerBorderColor.opacity(0.04)
          : Color.backgroundTertiary.opacity(0.17)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
          .fill(composerBorderColor.opacity(OpacityTier.tint))
      )
  }

  var surfaceBorder: some View {
    RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
      .strokeBorder(
        isFocused || inputMode != .prompt
          ? composerBorderColor.opacity(0.5)
          : Color.surfaceBorder.opacity(idleBorderOpacity),
        lineWidth: isFocused || inputMode != .prompt ? 1.5 : 1
      )
  }
}

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

struct DirectSessionComposerPendingInlineZone<Header: View, Content: View>: View {
  let modeColor: Color
  let isExpanded: Bool
  let contentHeight: CGFloat
  let onMeasuredHeightChanged: (CGFloat) -> Void
  @ViewBuilder let header: () -> Header
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(spacing: 0) {
      header()

      if isExpanded {
        ScrollView(.vertical, showsIndicators: true) {
          content()
            .background(
              GeometryReader { geometry in
                Color.clear.preference(
                  key: PendingPanelContentHeightPreferenceKey.self,
                  value: geometry.size.height
                )
              }
            )
        }
        .frame(height: contentHeight)
        .onPreferenceChange(PendingPanelContentHeightPreferenceKey.self) { measuredHeight in
          onMeasuredHeightChanged(max(0, measuredHeight))
        }
        .transition(.opacity.animation(Motion.gentle.delay(0.05)))
      }

      Rectangle()
        .fill(modeColor.opacity(OpacityTier.light))
        .frame(height: 0.5)
        .padding(.horizontal, Spacing.sm)
    }
  }
}

struct DirectSessionComposerPendingQuestionProgress: View {
  let currentIndex: Int
  let totalCount: Int
  let isCompactLayout: Bool
  let dotColors: [Color]

  var body: some View {
    HStack(alignment: .center, spacing: Spacing.sm) {
      Text("Question \(currentIndex + 1) of \(totalCount)")
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textTertiary)

      Spacer(minLength: 0)

      HStack(spacing: Spacing.xs) {
        ForEach(Array(dotColors.enumerated()), id: \.offset) { _, color in
          Circle()
            .fill(color)
            .frame(width: 6, height: 6)
        }
      }
    }
  }
}

struct DirectSessionComposerPendingQuestionOptionRow: View {
  let option: ApprovalQuestionOption
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(isSelected ? Color.statusQuestion : Color.textQuaternary)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(option.label)
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)

          if let description = option.description, !description.isEmpty {
            Text(description)
              .font(.system(size: TypeScale.micro, weight: .regular))
              .foregroundStyle(Color.textTertiary)
              .fixedSize(horizontal: false, vertical: true)
              .multilineTextAlignment(.leading)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.sm_)
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(isSelected ? Color.statusQuestion.opacity(OpacityTier.medium) : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .strokeBorder(
            isSelected
              ? Color.statusQuestion.opacity(OpacityTier.strong)
              : Color.surfaceBorder.opacity(OpacityTier.subtle),
            lineWidth: isSelected ? 1.5 : 1
          )
      )
    }
    .buttonStyle(.plain)
  }
}

struct DirectSessionComposerPendingFooterIconButton: View {
  let systemName: String
  let iconSize: CGFloat
  let dimension: CGFloat
  let fillColor: Color
  let isDisabled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: iconSize, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: dimension, height: dimension)
        .background(Circle().fill(fillColor))
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
  }
}
