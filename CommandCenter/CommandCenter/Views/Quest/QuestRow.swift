//
//  QuestRow.swift
//  OrbitDock
//
//  Compact quest card for lists
//

import SwiftUI

struct QuestRow: View {
  let quest: Quest
  let onSelect: () -> Void

  @State private var isHovering = false

  private var statusColor: Color {
    switch quest.status {
    case .active: Color.accent
    case .paused: Color.statusReply
    case .completed: Color.statusEnded
    }
  }

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 12) {
        // Status indicator
        Circle()
          .fill(statusColor)
          .frame(width: 8, height: 8)

        // Quest name
        VStack(alignment: .leading, spacing: 3) {
          Text(quest.name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          if let description = quest.description, !description.isEmpty {
            Text(description)
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        Spacer()

        // Stats
        HStack(spacing: 12) {
          // Session count
          if quest.sessionCount > 0 {
            HStack(spacing: 4) {
              Image(systemName: "cpu")
                .font(.system(size: 10))
              Text("\(quest.sessionCount)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.tertiary)
          }

          // Link count
          if quest.linkCount > 0 {
            HStack(spacing: 4) {
              Image(systemName: "link")
                .font(.system(size: 10))
              Text("\(quest.linkCount)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.tertiary)
          }

          // Status badge
          Text(quest.status.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.15), in: Capsule())
        }
      }
      .padding(.vertical, 10)
      .padding(.horizontal, 12)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isHovering ? Color.surfaceSelected : Color.backgroundTertiary.opacity(0.5))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(statusColor.opacity(isHovering ? 0.25 : 0.1), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }
}

#Preview {
  VStack(spacing: 8) {
    QuestRow(
      quest: Quest(
        id: "1",
        name: "Add OAuth to Vizzly",
        description: "Implement OAuth2 flow with Google and GitHub providers",
        status: .active,
        createdAt: Date(),
        updatedAt: Date()
      ),
      onSelect: {}
    )

    QuestRow(
      quest: Quest(
        id: "2",
        name: "Performance Optimization",
        status: .paused,
        createdAt: Date(),
        updatedAt: Date()
      ),
      onSelect: {}
    )

    QuestRow(
      quest: Quest(
        id: "3",
        name: "Dark Mode Support",
        description: "Add dark mode throughout the app",
        status: .completed,
        createdAt: Date(),
        updatedAt: Date(),
        completedAt: Date()
      ),
      onSelect: {}
    )
  }
  .padding()
  .background(Color.backgroundPrimary)
  .frame(width: 500)
}
