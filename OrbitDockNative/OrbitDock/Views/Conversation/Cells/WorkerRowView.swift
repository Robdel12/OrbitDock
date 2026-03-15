//
//  WorkerRowView.swift
//  OrbitDock
//
//  SwiftUI view for worker/subagent, plan, hook, and handoff rows.
//

import SwiftUI

struct WorkerRowView: View {
  let icon: String
  let iconColor: Color
  let title: String
  let subtitle: String?

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: icon)
        .font(.system(size: IconScale.md))
        .foregroundStyle(iconColor)
        .frame(width: IconScale.lg)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(title)
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.textSecondary)

        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
        }
      }

      Spacer()
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.vertical, Spacing.sm)
  }
}
