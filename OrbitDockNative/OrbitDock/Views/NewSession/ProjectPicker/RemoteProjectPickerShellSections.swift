import SwiftUI

struct RemoteProjectPickerSelectedPathBanner: View {
  let selectedPath: String
  let onCopy: () -> Void
  let onClear: () -> Void

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "folder.fill")
        .font(.system(size: 12))
        .foregroundStyle(Color.accent)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(URL(fileURLWithPath: selectedPath).lastPathComponent)
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.textPrimary)

        Text(ProjectPickerPlanner.displayPath(selectedPath))
          .font(.system(size: TypeScale.caption, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer()

      if !selectedPath.isEmpty {
        Button(action: onCopy) {
          Image(systemName: "doc.on.doc")
            .font(.system(size: 13))
            .foregroundStyle(Color.textQuaternary)
        }
        .buttonStyle(.plain)
      }

      Button(action: onClear) {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 14))
          .foregroundStyle(Color.textQuaternary)
      }
      .buttonStyle(.plain)
    }
    .padding(Spacing.md)
    .background(Color.accent.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.md))
  }
}

struct RemoteProjectPickerTabPicker<Tab: Hashable & CaseIterable>: View where Tab.AllCases: RandomAccessCollection {
  let tabs: Tab.AllCases
  let activeTab: Tab
  let title: (Tab) -> String
  let onSelect: (Tab) -> Void

  var body: some View {
    HStack(spacing: Spacing.xs) {
      ForEach(Array(tabs), id: \.self) { tab in
        Button {
          withAnimation(Motion.hover) {
            onSelect(tab)
          }
          Platform.services.playHaptic(.selection)
        } label: {
          Text(title(tab))
            .font(.system(size: TypeScale.body, weight: activeTab == tab ? .semibold : .medium))
            .foregroundStyle(activeTab == tab ? Color.accent : Color.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm + 1)
            .background(
              activeTab == tab
                ? Color.accent.opacity(OpacityTier.light)
                : Color.clear,
              in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(Spacing.xs)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }
}

struct RemoteProjectPickerTabContentCard<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      content()
    }
    .padding(Spacing.md)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }
}

struct RemoteProjectPickerPathPreviewSheet: View {
  let title: String
  let path: String
  let onDismiss: () -> Void
  let onCopy: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text("Full Path")
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
        .textCase(.uppercase)
        .tracking(0.5)

      Text(title)
        .font(.system(size: TypeScale.title, weight: .semibold))
        .foregroundStyle(Color.textPrimary)
        .lineLimit(1)
        .truncationMode(.middle)

      VStack(alignment: .leading, spacing: Spacing.sm) {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "folder")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          Text("Tap and hold to select")
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textQuaternary)
        }

        ScrollView {
          Text(path)
            .font(.system(size: TypeScale.caption, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(.vertical, Spacing.xxs)
        }
        .frame(maxHeight: 120)
      }
      .padding(Spacing.md)
      .background(
        Color.backgroundTertiary,
        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .stroke(Color.surfaceBorder, lineWidth: 1)
      )

      HStack(spacing: Spacing.sm) {
        Button(action: onDismiss) {
          Text("Done")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)

        Button(action: onCopy) {
          Label("Copy Path", systemImage: "doc.on.doc")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accent)
      }
    }
    .padding(Spacing.xl)
    .background(Color.backgroundSecondary)
  }
}
