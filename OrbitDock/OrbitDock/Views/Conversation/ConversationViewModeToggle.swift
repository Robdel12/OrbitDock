import SwiftUI

struct ConversationViewModeToggle: View {
  enum Presentation {
    case iconOnly
    case compactLabeled
  }

  @Binding var chatViewMode: ChatViewMode
  var presentation: Presentation = .iconOnly
  var showsContainerChrome: Bool = true
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var isCompact: Bool {
    horizontalSizeClass == .compact
  }

  var body: some View {
    HStack(spacing: toggleSpacing) {
      ForEach(ChatViewMode.allCases, id: \.self) { mode in
        modeButton(mode)
      }
    }
    .padding(containerPadding)
    .background {
      if showsContainerChrome {
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(Color.backgroundSecondary.opacity(0.9))
      }
    }
    .overlay {
      if showsContainerChrome {
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .strokeBorder(Color.surfaceBorder, lineWidth: 1)
      }
    }
  }

  private var toggleSpacing: CGFloat {
    switch presentation {
      case .iconOnly:
        isCompact ? Spacing.xs : Spacing.xxs
      case .compactLabeled:
        Spacing.xs
    }
  }

  private var containerPadding: CGFloat {
    if !showsContainerChrome {
      return 0
    }
    return switch presentation {
      case .iconOnly:
        isCompact ? Spacing.xs : Spacing.gap
      case .compactLabeled:
        Spacing.xs
    }
  }

  @ViewBuilder
  private func modeButton(_ mode: ChatViewMode) -> some View {
    let isSelected = chatViewMode == mode

    Button {
      withAnimation(Motion.gentle) {
        chatViewMode = mode
      }
      Platform.services.playHaptic(.selection)
    } label: {
      switch presentation {
        case .iconOnly:
          Image(systemName: mode.icon)
            .font(.system(size: isCompact ? 11 : 10, weight: .medium))
            .foregroundStyle(isSelected ? Color.accent : Color.textSecondary)
            .frame(width: isCompact ? 30 : 26, height: isCompact ? 24 : 22)
            .background(
              isSelected ? Color.accent.opacity(OpacityTier.light) : Color.clear,
              in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            )

        case .compactLabeled:
          HStack(spacing: Spacing.sm_) {
            Image(systemName: mode.icon)
              .font(.system(size: 10, weight: .medium))
            Text(modeTitle(mode))
              .font(.system(size: TypeScale.caption, weight: .semibold))
          }
          .foregroundStyle(isSelected ? Color.accent : Color.textSecondary)
          .padding(.horizontal, Spacing.sm + 2)
          .padding(.vertical, Spacing.sm_)
          .background(
            isSelected ? Color.accent.opacity(OpacityTier.light) : Color.clear,
            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          )
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(modeTitle(mode)) view")
    #if os(macOS)
      .help(mode.label)
    #endif
  }

  private func modeTitle(_ mode: ChatViewMode) -> String {
    switch mode {
      case .focused: "Grouped"
      case .verbose: "Verbose"
    }
  }
}
