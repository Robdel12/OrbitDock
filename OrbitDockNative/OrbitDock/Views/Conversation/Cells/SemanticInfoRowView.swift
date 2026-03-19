//
//  SemanticInfoRowView.swift
//  OrbitDock
//
//  Compact server-driven semantic row card.
//

import SwiftUI

struct SemanticInfoRowView: View {
  let icon: String
  let iconColor: Color
  let title: String
  let subtitle: String?
  let summary: String?
  let detail: String?

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      Image(systemName: icon)
        .font(.system(size: IconScale.md, weight: .semibold))
        .foregroundStyle(iconColor)
        .frame(width: IconScale.lg)

      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text(title)
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(Color.textPrimary)

        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textSecondary)
        }

        if let summary, !summary.isEmpty {
          Text(summary)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textSecondary)
        }

        if let detail, !detail.isEmpty, detail != summary {
          Text(detail)
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
            .textSelection(.enabled)
        }
      }

      Spacer()
    }
    .padding(Spacing.md)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(iconColor.opacity(0.22), lineWidth: 1)
    )
    .padding(.vertical, Spacing.xs)
  }
}
