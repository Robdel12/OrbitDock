import SwiftUI

struct QuickSwitcherQuickLaunchSection: View {
  let provider: QuickLaunchProvider
  let isCompactLayout: Bool
  let isLoadingProjects: Bool
  let recentProjects: [ServerRecentProject]
  let selectedIndex: Int
  let hoveredIndex: Int?
  let onOpenFullSheet: () -> Void
  let onHoverChanged: (Int, Bool) -> Void
  let onOpenProject: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: isCompactLayout ? Spacing.xxs : Spacing.xs) {
      HStack(spacing: isCompactLayout ? Spacing.sm_ : Spacing.sm) {
        Image(systemName: provider.icon)
          .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .semibold))
          .foregroundStyle(provider.color)

        Text("NEW \(provider.displayName.uppercased()) SESSION")
          .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .bold, design: .rounded))
          .foregroundStyle(provider.color)
          .tracking(0.8)

        Spacer()

        Button(action: onOpenFullSheet) {
          HStack(spacing: Spacing.xs) {
            Text("Full Options")
              .font(.system(size: isCompactLayout ? TypeScale.meta : TypeScale.micro, weight: .medium))
            Image(systemName: "arrow.up.right")
              .font(.system(size: isCompactLayout ? TypeScale.mini : 8, weight: .semibold))
          }
          .foregroundStyle(Color.textTertiary)
          .padding(.horizontal, isCompactLayout ? Spacing.md_ : Spacing.sm)
          .padding(.vertical, isCompactLayout ? 5 : Spacing.xs)
          .background(Color.surfaceHover, in: Capsule())
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, isCompactLayout ? Spacing.lg_ : Spacing.section)
      .padding(.top, isCompactLayout ? Spacing.sm_ : Spacing.sm)
      .padding(.bottom, isCompactLayout ? Spacing.xs : Spacing.sm)

      if isLoadingProjects {
        HStack {
          Spacer()
          ProgressView()
            .controlSize(.small)
          Spacer()
        }
        .padding(.vertical, isCompactLayout ? Spacing.section : Spacing.xl)
      } else if recentProjects.isEmpty {
        VStack(spacing: isCompactLayout ? Spacing.sm_ : Spacing.sm) {
          Image(systemName: "folder.badge.plus")
            .font(.system(size: isCompactLayout ? TypeScale.chatHeading2 : TypeScale.chatHeading1))
            .foregroundStyle(Color.textQuaternary)
          Text("No recent projects")
            .font(.system(size: isCompactLayout ? TypeScale.subhead : TypeScale.body))
            .foregroundStyle(Color.textTertiary)
          Text("Use Full Options to browse directories")
            .font(.system(size: isCompactLayout ? TypeScale.caption : TypeScale.meta))
            .foregroundStyle(Color.textQuaternary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, isCompactLayout ? Spacing.section : Spacing.xl)
      } else {
        ForEach(Array(recentProjects.enumerated()), id: \.element.id) { index, project in
          QuickSwitcherQuickLaunchProjectRow(
            project: project,
            provider: provider,
            index: index,
            isCompactLayout: isCompactLayout,
            isSelected: selectedIndex == index,
            isHovered: hoveredIndex == index,
            onHoverChanged: { hovered in
              onHoverChanged(index, hovered)
            },
            onOpenProject: {
              onOpenProject(project.path)
            }
          )
          .id("row-\(index)")
        }
      }
    }
  }
}

private struct QuickSwitcherQuickLaunchProjectRow: View {
  let project: ServerRecentProject
  let provider: QuickLaunchProvider
  let index: Int
  let isCompactLayout: Bool
  let isSelected: Bool
  let isHovered: Bool
  let onHoverChanged: (Bool) -> Void
  let onOpenProject: () -> Void

  private var iconSize: CGFloat {
    isCompactLayout ? 32 : 36
  }

  var body: some View {
    Button(action: onOpenProject) {
      HStack(spacing: isCompactLayout ? Spacing.md_ : Spacing.lg_) {
        ZStack {
          RoundedRectangle(cornerRadius: isCompactLayout ? 7 : 8, style: .continuous)
            .fill(provider.color.opacity(0.1))
            .frame(width: iconSize, height: iconSize)

          Image(systemName: "folder.fill")
            .font(.system(size: isCompactLayout ? TypeScale.subhead : TypeScale.title, weight: .medium))
            .foregroundStyle(provider.color.opacity(0.8))
        }

        VStack(alignment: .leading, spacing: isCompactLayout ? Spacing.xxs : Spacing.gap) {
          Text(URL(fileURLWithPath: project.path).lastPathComponent)
            .font(.system(size: isCompactLayout ? TypeScale.title : TypeScale.subhead, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text(QuickSwitcherRowPresentation.displayPath(project.path))
            .font(.system(size: isCompactLayout ? TypeScale.caption : TypeScale.meta, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Spacer(minLength: 4)

        HStack(spacing: Spacing.xs) {
          Image(systemName: "clock")
            .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.mini))
          Text("\(project.sessionCount)")
            .font(.system(size: isCompactLayout ? TypeScale.meta : TypeScale.micro, weight: .medium))
        }
        .foregroundStyle(Color.textQuaternary)
        .padding(.horizontal, isCompactLayout ? Spacing.md_ : Spacing.sm)
        .padding(.vertical, isCompactLayout ? 5 : Spacing.xs)
        .background(Color.surfaceHover, in: Capsule())
      }
      .padding(.horizontal, isCompactLayout ? Spacing.md : Spacing.lg)
      .padding(.vertical, Spacing.md_)
      .background(
        QuickSwitcherRowBackground(
          isSelected: isSelected,
          isHovered: isHovered
        )
      )
      .padding(.horizontal, isCompactLayout ? Spacing.xs : Spacing.sm)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered in
      guard !isCompactLayout else { return }
      onHoverChanged(hovered)
    }
  }
}
