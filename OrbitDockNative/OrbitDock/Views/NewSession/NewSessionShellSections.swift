import SwiftUI

struct NewSessionSheetShell<Header: View, FormContent: View, Footer: View>: View {
  @ViewBuilder let header: () -> Header
  @ViewBuilder let formContent: () -> FormContent
  @ViewBuilder let footer: () -> Footer

  var body: some View {
    let chrome = VStack(spacing: 0) {
      header()

      divider

      formContent()

      divider

      footer()
    }
    .background(
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .fill(Color.backgroundSecondary)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.32), radius: 28, y: 14)
    .shadow(color: Color.accent.opacity(0.08), radius: 18, y: 0)

    #if os(iOS)
      chrome
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    #else
      chrome
        .padding(Spacing.md)
        .frame(minWidth: 540, idealWidth: 620, maxWidth: 720)
    #endif
  }

  private var divider: some View {
    Rectangle()
      .fill(Color.surfaceBorder.opacity(OpacityTier.light))
      .frame(height: 1)
  }
}

struct NewSessionFormShell<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    #if os(iOS)
      ScrollView(showsIndicators: false) {
        content()
          .padding(.horizontal, Spacing.lg)
          .padding(.vertical, Spacing.lg)
          .padding(.bottom, Spacing.sm)
      }
    #else
      ScrollView(showsIndicators: true) {
        content()
          .padding(.horizontal, Spacing.lg)
          .padding(.vertical, Spacing.section)
      }
    #endif
  }
}

