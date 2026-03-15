//
//  SearchBarVisual.swift
//  OrbitDock
//
//  Decorative search input display (not interactive).
//  Used by GrepExpandedView, WebSearchExpandedView, ToolSearchExpandedView.
//

import SwiftUI

struct SearchBarVisual: View {
  let query: String
  var resultCount: Int?
  var icon: String = "magnifyingglass"
  var tintColor: Color = .toolSearch

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: icon)
        .font(.system(size: IconScale.md))
        .foregroundStyle(tintColor)

      Text(query)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textPrimary)
        .lineLimit(1)

      Spacer(minLength: 0)

      if let count = resultCount {
        Text("\(count) result\(count == 1 ? "" : "s")")
          .font(.system(size: TypeScale.mini, weight: .semibold, design: .monospaced))
          .foregroundStyle(tintColor)
          .padding(.horizontal, Spacing.sm_)
          .padding(.vertical, Spacing.xxs)
          .background(tintColor.opacity(OpacityTier.subtle), in: Capsule())
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(tintColor.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.ml))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.ml)
        .stroke(tintColor.opacity(OpacityTier.light), lineWidth: 1)
    )
  }
}
