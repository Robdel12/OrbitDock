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
      HStack(spacing: 10) {
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
        VStack(alignment: .leading, spacing: 2) {
          Text(toast.sessionName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          Text(message)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer(minLength: 8)

        // Dismiss button (shown on hover)
        if isHovering {
          Button(action: onDismiss) {
            Image(systemName: "xmark")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(.tertiary)
              .frame(width: 20, height: 20)
              .background(Color.surfaceHover, in: Circle())
          }
          .buttonStyle(.plain)
          .transition(.opacity)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.panelBackground)
          .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 4)
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
  @ObservedObject var toastManager: ToastManager
  let onSelectSession: (String) -> Void

  var body: some View {
    VStack(alignment: .trailing, spacing: 8) {
      ForEach(toastManager.toasts.prefix(3)) { toast in
        ToastView(
          toast: toast,
          onTap: {
            onSelectSession(toast.sessionId)
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
    .padding(16)
    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: toastManager.toasts)
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
        VStack(alignment: .trailing, spacing: 8) {
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
        .padding(16)
      }
    }
  }
  .frame(width: 400, height: 300)
}
