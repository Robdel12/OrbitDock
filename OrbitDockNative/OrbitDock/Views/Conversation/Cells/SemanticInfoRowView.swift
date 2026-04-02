//
//  SemanticInfoRowView.swift
//  OrbitDock
//
//  Compact server-driven semantic row card.
//

import SwiftUI

struct SemanticInfoRowView: View {
  enum Density {
    case standard
    case compact
  }

  enum Emphasis {
    case standard
    case subtle
  }

  let icon: String
  let iconColor: Color
  let title: String
  let subtitle: String?
  let summary: String?
  let detail: String?
  var density: Density = .standard
  var emphasis: Emphasis = .standard

  private var iconSize: CGFloat {
    density == .compact ? IconScale.sm : IconScale.md
  }

  private var iconFrameWidth: CGFloat {
    density == .compact ? IconScale.md : IconScale.lg
  }

  private var titleFontSize: CGFloat {
    density == .compact ? TypeScale.caption : TypeScale.body
  }

  private var secondaryFontSize: CGFloat {
    density == .compact ? TypeScale.micro : TypeScale.caption
  }

  private var rowPadding: CGFloat {
    density == .compact ? Spacing.sm : Spacing.md
  }

  private var verticalPadding: CGFloat {
    density == .compact ? Spacing.xxs : Spacing.xs
  }

  private var textStackSpacing: CGFloat {
    density == .compact ? Spacing.xxs : Spacing.xs
  }

  private var borderOpacity: CGFloat {
    switch emphasis {
      case .standard:
        return density == .compact ? 0.16 : 0.22
      case .subtle:
        return density == .compact ? 0.10 : 0.14
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      Image(systemName: icon)
        .font(.system(size: iconSize, weight: .semibold))
        .foregroundStyle(iconColor)
        .frame(width: iconFrameWidth)

      VStack(alignment: .leading, spacing: textStackSpacing) {
        Text(title)
          .font(.system(size: titleFontSize, weight: .semibold))
          .foregroundStyle(Color.textPrimary)

        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.system(size: secondaryFontSize))
            .foregroundStyle(Color.textSecondary)
        }

        if let summary, !summary.isEmpty {
          Text(summary)
            .font(.system(size: secondaryFontSize))
            .foregroundStyle(Color.textSecondary)
        }

        if let detail, !detail.isEmpty, detail != summary {
          Text(detail)
            .font(.system(size: density == .compact ? TypeScale.micro : TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
            .textSelection(.enabled)
        }
      }

      Spacer()
    }
    .padding(rowPadding)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(iconColor.opacity(borderOpacity), lineWidth: 1)
    )
    .padding(.vertical, verticalPadding)
  }
}
