import SwiftUI

struct ConversationViewModeToggle: View {
  @Binding var chatViewMode: ChatViewMode
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var isCompact: Bool {
    horizontalSizeClass == .compact
  }

  var body: some View {
    HStack(spacing: isCompact ? 4 : 2) {
      ForEach(ChatViewMode.allCases, id: \.self) { mode in
        modeButton(mode)
      }
    }
    .padding(isCompact ? 4 : 3)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundSecondary.opacity(0.9))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(Color.surfaceBorder, lineWidth: 1)
    )
  }

  @ViewBuilder
  private func modeButton(_ mode: ChatViewMode) -> some View {
    let isSelected = chatViewMode == mode

    Button {
      withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
        chatViewMode = mode
      }
    } label: {
      Image(systemName: mode.icon)
        .font(.system(size: isCompact ? 11 : 10, weight: .medium))
        .foregroundStyle(isSelected ? Color.accent : .secondary)
        .frame(width: isCompact ? 30 : 26, height: isCompact ? 24 : 22)
        .background(
          isSelected ? Color.accent.opacity(OpacityTier.light) : Color.clear,
          in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        )
    }
    .buttonStyle(.plain)
    #if os(macOS)
      .help(mode.label)
    #endif
  }
}
