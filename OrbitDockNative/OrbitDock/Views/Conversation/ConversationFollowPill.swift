//
//  ConversationFollowPill.swift
//  OrbitDock
//
//  Floating "scroll to bottom" indicator overlaid on the conversation timeline.
//  Appears when the user scrolls up (unpinned). Small trailing circle with
//  optional unread count badge overlay.
//

import SwiftUI

struct ConversationFollowPill: View {
  let unreadCount: Int
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      Image(systemName: "chevron.down")
        .font(.system(size: TypeScale.micro, weight: .bold))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 28, height: 28)
        .background(
          Circle()
            .fill(Color.backgroundTertiary.opacity(0.85))
            .themeShadow(Shadow.sm)
        )
        .overlay(
          Circle()
            .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 0.5)
        )
        .overlay(alignment: .topTrailing) {
          if unreadCount > 0 {
            Text("\(min(unreadCount, 99))")
              .font(.system(size: 8, weight: .bold, design: .monospaced))
              .foregroundStyle(.white)
              .padding(.horizontal, Spacing.xs)
              .padding(.vertical, 1)
              .background(Color.accent, in: Capsule())
              .offset(x: 6, y: -4)
          }
        }
    }
    .buttonStyle(.plain)
  }
}
