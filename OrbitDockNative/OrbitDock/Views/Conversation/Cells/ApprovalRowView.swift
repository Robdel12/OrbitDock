//
//  ApprovalRowView.swift
//  OrbitDock
//
//  SwiftUI view for approval/permission and question cards.
//

import SwiftUI

struct ApprovalRowView: View {
  let title: String
  let subtitle: String?
  let summary: String?
  let isQuestion: Bool

  private var accentColor: Color {
    isQuestion ? .statusQuestion : .statusPermission
  }

  private var iconName: String {
    isQuestion ? "questionmark.bubble.fill" : "exclamationmark.triangle.fill"
  }

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      Image(systemName: iconName)
        .font(.system(size: IconScale.xl, weight: .semibold))
        .foregroundStyle(accentColor)

      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text(title)
          .font(.system(size: TypeScale.subhead, weight: .semibold))
          .foregroundStyle(Color.textPrimary)

        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.system(size: TypeScale.body))
            .foregroundStyle(Color.textSecondary)
        }

        if let summary, !summary.isEmpty {
          Text(summary)
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
        }
      }

      Spacer()
    }
    .padding(Spacing.md)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(accentColor.opacity(0.3), lineWidth: 1)
    )
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 1.5)
        .fill(accentColor)
        .frame(width: EdgeBar.width)
        .padding(.vertical, Spacing.xs)
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.vertical, Spacing.xs)
  }
}
