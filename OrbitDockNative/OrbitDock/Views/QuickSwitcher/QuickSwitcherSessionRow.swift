import SwiftUI

struct QuickSwitcherSessionRow: View {
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  let session: RootSessionNode
  let index: Int
  let isCompactLayout: Bool
  let isSelected: Bool
  let isHovered: Bool
  let onHoverChanged: (Bool) -> Void
  let onNavigate: () -> Void
  let onOpenInFinder: () -> Void
  let onRename: () -> Void
  let onCopyResume: () -> Void
  let onClose: (() -> Void)?

  private var displayStatus: SessionDisplayStatus {
    session.displayStatus
  }

  private var isHighlighted: Bool {
    isSelected || isHovered
  }

  var body: some View {
    Button(action: onNavigate) {
      HStack(spacing: isCompactLayout ? Spacing.md_ : Spacing.lg_) {
        SessionStatusDot(status: displayStatus, size: isCompactLayout ? 8 : 10, showGlow: !isCompactLayout)
          .frame(
            width: isCompactLayout ? Spacing.lg : Spacing.section,
            height: isCompactLayout ? Spacing.lg : Spacing.section
          )

        VStack(alignment: .leading, spacing: isCompactLayout ? Spacing.xxs : Spacing.xs) {
          HStack(spacing: isCompactLayout ? Spacing.sm_ : Spacing.sm) {
            Text(QuickSwitcherRowPresentation.projectName(for: session))
              .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .medium))
              .foregroundStyle(Color.textSecondary)
              .lineLimit(1)

            if !isCompactLayout, session.endpointName != nil {
              EndpointBadge(
                endpointName: session.endpointName,
                isDefault: session.endpointId == runtimeRegistry.activeEndpointId
              )
            }

            if let branch = session.branch {
              HStack(spacing: Spacing.gap) {
                Image(systemName: "arrow.triangle.branch")
                  .font(.system(size: isCompactLayout ? 8 : TypeScale.mini))
                Text(branch)
                  .font(.system(size: isCompactLayout ? TypeScale.mini : TypeScale.micro, design: .monospaced))
                  .lineLimit(1)
              }
              .foregroundStyle(Color.gitBranch.opacity(0.7))
            }

          }

          HStack(spacing: isCompactLayout ? Spacing.sm : Spacing.md_) {
            Text(session.displayName)
              .font(.system(size: isCompactLayout ? TypeScale.title : TypeScale.subhead, weight: .semibold))
              .foregroundStyle(.primary)
              .lineLimit(1)

            if session.showsInMissionControl {
              QuickSwitcherSessionActivityBadge(
                session: session,
                status: displayStatus
              )
            } else {
              HStack(spacing: Spacing.xs) {
                if let endedAt = session.endedAt {
                  Text(endedAt, style: .relative)
                    .font(.system(size: isCompactLayout ? TypeScale.meta : TypeScale.micro))
                }
              }
              .foregroundStyle(Color.statusEnded)
            }
          }
        }

        Spacer(minLength: 4)

        if isCompactLayout {
          UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)
        } else if isHighlighted {
          HStack(spacing: Spacing.xs) {
            quickSwitcherActionButton(icon: "folder", tooltip: "Open in Finder", action: onOpenInFinder)
            quickSwitcherActionButton(icon: "pencil", tooltip: "Rename", action: onRename)
            quickSwitcherActionButton(icon: "doc.on.doc", tooltip: "Copy Resume", action: onCopyResume)
            if let onClose {
              quickSwitcherActionButton(icon: "xmark.circle", tooltip: "End Session", action: onClose)
            }
          }
          .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else {
          UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)
        }
      }
      .padding(.horizontal, isCompactLayout ? Spacing.md : Spacing.lg)
      .padding(.vertical, isCompactLayout ? Spacing.md_ : Spacing.md)
      .background(
        QuickSwitcherRowBackground(
          isSelected: isSelected,
          isHovered: isHovered
        )
      )
      .padding(.horizontal, isCompactLayout ? Spacing.xs : Spacing.sm)
      .contentShape(Rectangle())
      .animation(Motion.hover, value: isHighlighted)
    }
    .buttonStyle(.plain)
    .onHover { hovered in
      guard !isCompactLayout else { return }
      onHoverChanged(hovered)
    }
    .modifier(CompactContextMenuModifier(isCompact: isCompactLayout) {
      Button(action: onOpenInFinder) {
        Label("Open in Files", systemImage: "folder")
      }

      Button(action: onRename) {
        Label("Rename", systemImage: "pencil")
      }

      Button(action: onCopyResume) {
        Label("Copy Resume Command", systemImage: "doc.on.doc")
      }

      if let onClose {
        Divider()
        Button(role: .destructive, action: onClose) {
          Label("End Session", systemImage: "xmark.circle")
        }
      }
    })
  }
}

private struct QuickSwitcherSessionActivityBadge: View {
  let session: RootSessionNode
  let status: SessionDisplayStatus

  var body: some View {
    let color = status.color

    HStack(spacing: Spacing.xs) {
      Image(systemName: QuickSwitcherRowPresentation.activityIcon(for: session, status: status))
        .font(.system(size: TypeScale.mini, weight: .medium))
      Text(QuickSwitcherRowPresentation.activityText(for: session, status: status))
        .font(.system(size: TypeScale.micro, weight: .medium))
    }
    .foregroundStyle(color)
    .padding(.horizontal, Spacing.sm_)
    .padding(.vertical, Spacing.xxs)
    .background(color.opacity(0.12), in: Capsule())
  }
}

private func quickSwitcherActionButton(icon: String, tooltip: String, action: @escaping () -> Void) -> some View {
  Button(action: action) {
    Image(systemName: icon)
      .font(.system(size: TypeScale.caption, weight: .medium))
      .foregroundStyle(.secondary)
      .frame(width: 28, height: 28)
      .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
  }
  .buttonStyle(.plain)
  .help(tooltip)
}
