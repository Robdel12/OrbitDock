//
//  ActivityGroupRowView.swift
//  OrbitDock
//
//  SwiftUI view for collapsible activity groups.
//

import SwiftUI

struct ActivityGroupRowView: View {
  let group: ServerConversationActivityGroupRow
  let isExpanded: Bool
  var sessionId: String = ""
  var clients: ServerClients?

  private var statusColor: Color {
    group.status == .completed ? .feedbackPositive : .accent
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header
      HStack(spacing: Spacing.sm_) {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(.system(size: IconScale.xs, weight: .semibold))
          .foregroundStyle(Color.textTertiary)

        Text(group.title)
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.textSecondary)

        Spacer()

        Text("\(group.childCount)")
          .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
          .foregroundStyle(statusColor)
      }
      .padding(.horizontal, Spacing.xl)
      .padding(.vertical, Spacing.sm)
      .contentShape(Rectangle())

      // Expanded children
      if isExpanded {
        VStack(spacing: 0) {
          ForEach(group.children, id: \.id) { child in
            ToolCardView(toolRow: child, isExpanded: false, sessionId: sessionId, clients: clients)
          }
        }
        .padding(.leading, Spacing.lg)
      }
    }
  }
}
