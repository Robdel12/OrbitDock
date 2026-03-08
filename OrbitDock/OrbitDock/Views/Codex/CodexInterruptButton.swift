//
//  CodexInterruptButton.swift
//  OrbitDock
//
//  Interrupt button for active Codex/Claude sessions.
//

import SwiftUI

struct CodexInterruptButton: View {
  let sessionId: String
  var isCompact: Bool = false
  @Environment(ServerAppState.self) private var serverState

  @State private var isInterrupting = false
  @State private var isHovering = false

  private var size: CGFloat {
    isCompact ? 34 : 26
  }

  var body: some View {
    Button(action: interrupt) {
      Group {
        if isInterrupting {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: "stop.fill")
            .font(.system(size: isCompact ? 14 : 12, weight: .semibold))
        }
      }
      .foregroundStyle(Color.statusError)
      .frame(width: size, height: size)
      .background(
        Color.statusError.opacity(isHovering ? OpacityTier.medium : OpacityTier.light),
        in: RoundedRectangle(cornerRadius: isCompact ? Radius.md : Radius.sm, style: .continuous)
      )
    }
    .buttonStyle(.plain)
    .disabled(isInterrupting)
    .platformHover($isHovering)
    .animation(Motion.hover, value: isHovering)
    .help("Stop")
    .onChange(of: workStatus) { _, newValue in
      if isInterrupting, newValue != .working {
        isInterrupting = false
      }
    }
  }

  private func interrupt() {
    isInterrupting = true
    Platform.services.playHaptic(.destructive)
    serverState.interruptSession(sessionId)
  }

  private var workStatus: Session.WorkStatus {
    serverState.session(sessionId).workStatus
  }
}
