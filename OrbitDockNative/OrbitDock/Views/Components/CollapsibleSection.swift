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
  var badge: String?
  var badgeColor: Color = .accent
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(spacing: 0) {
      // Header
      Button {
        withAnimation(Motion.standard) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))

          Image(systemName: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)

          Text(title)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(.secondary)

          if let badge {
            Text(badge)
              .font(.system(size: TypeScale.meta, weight: .medium, design: .rounded))
              .foregroundStyle(badgeColor)
              .padding(.horizontal, Spacing.sm_)
              .padding(.vertical, Spacing.xxs)
              .background(badgeColor.opacity(0.12), in: Capsule())
          }

          Spacer()
        }
        .padding(.vertical, Spacing.md_)
        .padding(.horizontal, Spacing.md)
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
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Step 1: Do the thing")
        Text("Step 2: Do more things")
      }
      .padding(Spacing.md)
    }

    CollapsibleSection(title: "Changes", icon: "doc.badge.plus", isExpanded: $collapsed) {
      Text("Diff content here")
        .padding(Spacing.md)
    }
  }
  .background(Color.backgroundSecondary)
  .frame(width: 320, height: 300)
}
