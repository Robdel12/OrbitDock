//
//  UsageGaugeBar.swift
//  OrbitDock
//
//  Reusable usage gauge bar with optional projection overlay.
//  Caller controls size via .frame(width:height:).
//

import SwiftUI

struct UsageGaugeBar: View {
  let utilization: Double
  let usageColor: Color
  let projectedAtReset: Double
  let showProjection: Bool

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: Radius.xs)
          .fill(Color.primary.opacity(0.1))

        if showProjection {
          RoundedRectangle(cornerRadius: Radius.xs)
            .fill(DashboardFormatters.projectedColor(projectedAtReset).opacity(0.3))
            .frame(width: geo.size.width * min(1, projectedAtReset / 100))
        }

        RoundedRectangle(cornerRadius: Radius.xs)
          .fill(usageColor)
          .frame(width: geo.size.width * min(1, utilization / 100))
      }
    }
  }
}
