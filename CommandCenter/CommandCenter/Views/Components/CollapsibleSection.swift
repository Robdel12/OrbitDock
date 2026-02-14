//
//  CollapsibleSection.swift
//  OrbitDock
//
//  Reusable disclosure section for the right rail.
//

import SwiftUI

struct CollapsibleSection<Content: View>: View {
  let title: String
  let icon: String
  @Binding var isExpanded: Bool
  var badge: String? = nil
  var badgeColor: Color = .accent
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(spacing: 0) {
      // Header
      Button {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))

          Image(systemName: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)

          Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)

          if let badge {
            Text(badge)
              .font(.system(size: 11, weight: .medium, design: .rounded))
              .foregroundStyle(badgeColor)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(badgeColor.opacity(0.12), in: Capsule())
          }

          Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .background(Color.backgroundTertiary.opacity(0.3))
      }
      .buttonStyle(.plain)

      // Content
      if isExpanded {
        content()
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }
}

#Preview {
  @Previewable @State var expanded = true
  @Previewable @State var collapsed = false

  VStack(spacing: 1) {
    CollapsibleSection(title: "Plan", icon: "list.bullet.clipboard", isExpanded: $expanded, badge: "3/5") {
      VStack(alignment: .leading, spacing: 4) {
        Text("Step 1: Do the thing")
        Text("Step 2: Do more things")
      }
      .padding(12)
    }

    CollapsibleSection(title: "Changes", icon: "doc.badge.plus", isExpanded: $collapsed) {
      Text("Diff content here")
        .padding(12)
    }
  }
  .background(Color.backgroundSecondary)
  .frame(width: 320, height: 300)
}
