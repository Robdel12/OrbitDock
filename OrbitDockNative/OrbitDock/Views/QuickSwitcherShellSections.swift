import SwiftUI

struct QuickSwitcherShell<SearchBar: View, Content: View, EmptyState: View, Footer: View>: View {
  let isCompactLayout: Bool
  let isEmptyState: Bool
  @ViewBuilder let searchBar: () -> SearchBar
  @ViewBuilder let content: () -> Content
  @ViewBuilder let emptyState: () -> EmptyState
  @ViewBuilder let footer: () -> Footer

  var body: some View {
    VStack(spacing: 0) {
      searchBar()

      Divider()
        .foregroundStyle(Color.panelBorder)

      if isEmptyState {
        emptyState()
      } else {
        content()
      }

      if !isCompactLayout {
        footer()
      }
    }
    .frame(maxWidth: isCompactLayout ? .infinity : 720)
    .background {
      if isCompactLayout {
        Color.backgroundSecondary
          .ignoresSafeArea(.container, edges: .bottom)
      } else {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(Color.backgroundSecondary)
      }
    }
    .overlay {
      if !isCompactLayout {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(Color.panelBorder, lineWidth: 1)
      }
    }
    .clipShape(
      isCompactLayout
        ? AnyShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        : AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    )
    .themeShadow(Shadow.lg)
    .padding(.horizontal, isCompactLayout ? Spacing.sm_ : 0)
  }
}

struct QuickSwitcherResultsShell<Content: View>: View {
  let isCompactLayout: Bool
  let selectedIndex: Int
  @ViewBuilder let content: () -> Content

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          content()
        }
        .padding(.vertical, isCompactLayout ? Spacing.xs : Spacing.sm)
      }
      .frame(maxHeight: isCompactLayout ? 560 : 620)
      .onChange(of: selectedIndex) { _, newIndex in
        proxy.scrollTo("row-\(newIndex)", anchor: .center)
      }
    }
  }
}
