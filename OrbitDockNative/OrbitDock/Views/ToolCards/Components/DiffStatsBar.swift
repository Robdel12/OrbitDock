//
//  DiffStatsBar.swift
//  OrbitDock
//
//  Proportional green/red horizontal bar showing +N/-M change stats.
//  Used by EditExpandedView for visual change weight at a glance.
//

import SwiftUI

struct DiffStatsBar: View {
  let additions: Int
  let deletions: Int
  var maxWidth: CGFloat = 80

  private var total: Int { additions + deletions }

  var body: some View {
    HStack(spacing: Spacing.sm_) {
      // Stats text
      if additions > 0 {
        Text("+\(additions)")
          .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.diffAddedAccent)
      }
      if deletions > 0 {
        Text("-\(deletions)")
          .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.diffRemovedAccent)
      }

      // Proportional bar
      if total > 0 {
        GeometryReader { geo in
          let width = min(geo.size.width, maxWidth)
          let addWidth = width * CGFloat(additions) / CGFloat(total)
          let delWidth = width * CGFloat(deletions) / CGFloat(total)

          HStack(spacing: 1) {
            if additions > 0 {
              RoundedRectangle(cornerRadius: Radius.xs)
                .fill(Color.diffAddedAccent)
                .frame(width: max(addWidth, 2))
            }
            if deletions > 0 {
              RoundedRectangle(cornerRadius: Radius.xs)
                .fill(Color.diffRemovedAccent)
                .frame(width: max(delWidth, 2))
            }
          }
          .frame(width: width, alignment: .leading)
        }
        .frame(width: maxWidth, height: 4)
      }
    }
  }
}

/// Micro diff stats bar for compact card inline preview — just the proportional bar, no text.
struct MicroDiffStatsBar: View {
  let additions: Int
  let deletions: Int
  var maxWidth: CGFloat = 60

  private var total: Int { additions + deletions }

  var body: some View {
    if total > 0 {
      GeometryReader { geo in
        let width = min(geo.size.width, maxWidth)
        let addWidth = width * CGFloat(additions) / CGFloat(total)
        let delWidth = width * CGFloat(deletions) / CGFloat(total)

        HStack(spacing: 1) {
          if additions > 0 {
            RoundedRectangle(cornerRadius: Radius.xs)
              .fill(Color.diffAddedAccent)
              .frame(width: max(addWidth, 2))
          }
          if deletions > 0 {
            RoundedRectangle(cornerRadius: Radius.xs)
              .fill(Color.diffRemovedAccent)
              .frame(width: max(delWidth, 2))
          }
        }
        .frame(width: width, alignment: .leading)
      }
      .frame(width: maxWidth, height: 4)
    }
  }
}
