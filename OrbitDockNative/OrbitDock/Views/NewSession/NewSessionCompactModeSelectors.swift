import SwiftUI

struct CompactClaudePermissionSelector: View {
  @Binding var selection: ClaudePermissionMode
  @State private var hoveredMode: ClaudePermissionMode?

  private let modes = ClaudePermissionMode.allCases

  var body: some View {
    HStack(spacing: Spacing.sm) {
      ForEach(modes) { mode in
        CompactModeButton(
          icon: mode.icon,
          color: mode.color,
          isActive: mode == selection,
          isHovered: hoveredMode == mode && mode != selection,
          helpText: mode.displayName,
          onTap: { selection = mode },
          onHover: { hovering in hoveredMode = hovering ? mode : nil }
        )
      }
    }
    #if !os(iOS)
      .onHover { hovering in
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
          hoveredMode = nil
        }
      }
    #endif
      .animation(Motion.bouncy, value: hoveredMode)
      .animation(Motion.bouncy, value: selection)
  }
}

struct CompactAutonomySelector: View {
  @Binding var selection: AutonomyLevel
  @State private var hoveredLevel: AutonomyLevel?

  private let levels = AutonomyLevel.allCases

  var body: some View {
    HStack(spacing: Spacing.sm) {
      ForEach(levels) { level in
        CompactModeButton(
          icon: level.icon,
          color: level.color,
          isActive: level == selection,
          isHovered: hoveredLevel == level && level != selection,
          helpText: level.displayName,
          onTap: { selection = level },
          onHover: { hovering in hoveredLevel = hovering ? level : nil }
        )
      }
    }
    #if !os(iOS)
      .onHover { hovering in
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
          hoveredLevel = nil
        }
      }
    #endif
      .animation(Motion.bouncy, value: hoveredLevel)
      .animation(Motion.bouncy, value: selection)
  }
}

private struct CompactModeButton: View {
  let icon: String
  let color: Color
  let isActive: Bool
  let isHovered: Bool
  let helpText: String
  let onTap: () -> Void
  let onHover: (Bool) -> Void

  var body: some View {
    Button(action: {
      onTap()
      #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
      #endif
    }) {
      let iconColor = isActive ? Color.backgroundSecondary : (isHovered ? color : color.opacity(0.6))
      let scale = isActive ? 1.05 : 1.0

      Image(systemName: icon)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(iconColor)
        .frame(width: 30, height: 30)
        .background(backgroundCircle)
        .overlay(strokeCircle)
        .themeShadow(Shadow.glow(color: isActive ? color : .clear))
        .scaleEffect(scale)
    }
    .buttonStyle(.plain)
    #if !os(iOS)
      .onHover(perform: onHover)
      .help(helpText)
    #endif
      .contentShape(Circle())
  }

  @ViewBuilder
  private var backgroundCircle: some View {
    if isActive {
      Circle().fill(color)
    } else if isHovered {
      Circle().fill(color.opacity(OpacityTier.light))
    } else {
      Circle().fill(Color.clear)
    }
  }

  @ViewBuilder
  private var strokeCircle: some View {
    let strokeColor = isActive ? Color.clear : (isHovered ? color.opacity(OpacityTier.strong) : color.opacity(0.3))
    let strokeWidth: CGFloat = isActive ? 0 : (isHovered ? 1.5 : 1)

    Circle().stroke(strokeColor, lineWidth: strokeWidth)
  }
}
