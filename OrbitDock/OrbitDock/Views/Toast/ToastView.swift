//
//  ToastView.swift
//  OrbitDock
//
//  Non-intrusive toast notification for session status changes
//

import SwiftUI

struct SessionToast: Identifiable, Equatable {
  let id = UUID()
  let sessionId: String
  let sessionName: String
  let status: SessionDisplayStatus
  let detail: String? // e.g., tool name for permission, question text
  let createdAt = Date()

  static func == (lhs: SessionToast, rhs: SessionToast) -> Bool {
    lhs.id == rhs.id
  }
}

struct ToastView: View {
  let toast: SessionToast
  let onTap: () -> Void
  let onDismiss: () -> Void

  @State private var isHovering = false

  private var statusColor: Color {
    toast.status.color
  }

  private var icon: String {
    toast.status.icon
  }

  private var message: String {
    switch toast.status {
      case .permission:
        if let tool = toast.detail {
          return "needs permission: \(tool)"
        }
        return "needs permission"
      case .question:
        return "has a question"
      default:
        return "needs attention"
    }
  }

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: Spacing.md_) {
        // Status indicator
        ZStack {
          Circle()
            .fill(statusColor.opacity(0.2))
            .frame(width: 28, height: 28)

          Image(systemName: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(statusColor)
        }

        // Content
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(toast.sessionName)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          Text(message)
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer(minLength: Spacing.sm)

        // Dismiss button (shown on hover)
        if isHovering {
          Button(action: onDismiss) {
            Image(systemName: "xmark")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(Color.textTertiary)
              .frame(width: 20, height: 20)
              .background(Color.surfaceHover, in: Circle())
          }
          .buttonStyle(.plain)
          .transition(.opacity)
        }
      }
      .padding(.horizontal, Spacing.lg_)
      .padding(.vertical, Spacing.md_)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.panelBackground)
          .themeShadow(Shadow.lg)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(statusColor.opacity(0.3), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .frame(width: 280)
  }
}

// MARK: - Toast Container

struct ToastContainer: View {
  @Environment(AppRouter.self) private var router
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  @ObservedObject var toastManager: ToastManager

  var body: some View {
    VStack(alignment: .trailing, spacing: Spacing.sm) {
      ForEach(toastManager.toasts.prefix(3)) { toast in
        ToastView(
          toast: toast,
          onTap: {
            withAnimation(Motion.standard) {
              router.navigateToSession(scopedID: toast.sessionId, runtimeRegistry: runtimeRegistry)
            }
            toastManager.dismiss(toast)
          },
          onDismiss: {
            toastManager.dismiss(toast)
          }
        )
        .transition(.asymmetric(
          insertion: .move(edge: .trailing).combined(with: .opacity),
          removal: .opacity.combined(with: .scale(scale: 0.9))
        ))
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.top, 48)
    .padding(.bottom, Spacing.lg)
    .animation(Motion.gentle, value: toastManager.toasts)
  }
}

// MARK: - Preview

#Preview {
  ZStack {
    Color.backgroundPrimary
      .ignoresSafeArea()

    VStack {
      Spacer()
      HStack {
        Spacer()
        VStack(alignment: .trailing, spacing: Spacing.sm) {
          ToastView(
            toast: SessionToast(
              sessionId: "1",
              sessionName: "vizzly-cli",
              status: .permission,
              detail: "Bash"
            ),
            onTap: {},
            onDismiss: {}
          )

          ToastView(
            toast: SessionToast(
              sessionId: "2",
              sessionName: "claude-dashboard",
              status: .question,
              detail: nil
            ),
            onTap: {},
            onDismiss: {}
          )
        }
        .padding(Spacing.lg)
      }
    }
  }
  .frame(width: 400, height: 300)
}
