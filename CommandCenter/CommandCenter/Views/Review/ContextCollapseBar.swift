//
//  ContextCollapseBar.swift
//  OrbitDock
//
//  Collapsible bar between hunks showing hidden unchanged lines.
//

import SwiftUI

struct ContextCollapseBar: View {
  let hiddenLineCount: Int
  @Binding var isExpanded: Bool

  @State private var isHovered = false

  var body: some View {
    if hiddenLineCount > 0 {
      Button {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 0) {
          // Gutter zone — matches the diff gutter width (3px edge + 72px numbers + 1px border)
          HStack(spacing: 0) {
            // Fold indicators
            Text("\u{22EF}")
              .font(.system(size: 11, weight: .light))
              .foregroundStyle(.tertiary)
              .frame(maxWidth: .infinity)
          }
          .frame(width: 76)
          .background(Color.white.opacity(0.015))

          Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(width: 1)

          // Content zone
          HStack(spacing: 6) {
            Image(systemName: isExpanded ? "chevron.up.2" : "chevron.down.2")
              .font(.system(size: 7, weight: .bold))
              .foregroundStyle(isHovered ? Color.accent : Color.white.opacity(0.2))

            Text(isExpanded ? "Hide \(hiddenLineCount) unchanged lines" : "\(hiddenLineCount) lines hidden")
              .font(.system(size: 9.5, weight: .medium))
              .foregroundStyle(isHovered ? .secondary : .tertiary)

            // Decorative rule line
            Rectangle()
              .fill(Color.panelBorder)
              .frame(height: 1)
              .frame(maxWidth: .infinity)
          }
          .padding(.horizontal, 12)
        }
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(
          isHovered
            ? Color.accent.opacity(0.03)
            : Color.backgroundTertiary.opacity(0.3)
        )
      }
      .buttonStyle(.plain)
      .onHover { hovering in
        isHovered = hovering
      }
    }
  }
}
