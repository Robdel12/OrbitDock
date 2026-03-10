import SwiftUI

struct HeaderShell<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    content()
      .background(Color.backgroundSecondary)
  }
}

struct HeaderRegularShell<Leading: View, Intelligence: View, Controls: View>: View {
  @ViewBuilder let leading: () -> Leading
  @ViewBuilder let intelligence: () -> Intelligence
  @ViewBuilder let controls: () -> Controls

  var body: some View {
    HStack(spacing: Spacing.md) {
      leading()

      Spacer()

      intelligence()
      controls()
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
  }
}

struct HeaderCompactShell<PrimaryRow: View, ControlRow: View>: View {
  @ViewBuilder let primaryRow: () -> PrimaryRow
  @ViewBuilder let controlRow: () -> ControlRow

  var body: some View {
    VStack(spacing: Spacing.sm) {
      primaryRow()
      controlRow()
    }
    .padding(.vertical, Spacing.sm)
  }
}
