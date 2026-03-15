//
//  ProgressSummaryBar.swift
//  OrbitDock
//
//  Horizontal progress fill bar for todo completion display.
//  Used by TodoExpandedView for visual progress tracking.
//

import SwiftUI

struct ProgressSummaryBar: View {
  let completed: Int
  let total: Int
  var barColor: Color = .feedbackPositive

  private var fraction: CGFloat {
    total > 0 ? CGFloat(completed) / CGFloat(total) : 0
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: Radius.xs)
            .fill(barColor.opacity(OpacityTier.subtle))
            .frame(height: 6)

          RoundedRectangle(cornerRadius: Radius.xs)
            .fill(barColor)
            .frame(width: geo.size.width * fraction, height: 6)
        }
      }
      .frame(height: 6)

      Text("\(completed) of \(total) tasks complete")
        .font(.system(size: TypeScale.mini, weight: .medium))
        .foregroundStyle(Color.textTertiary)
    }
  }
}
