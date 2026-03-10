//
//  RateLimitBanner.swift
//  OrbitDock
//
//  Inline banner shown in the composer area when Claude reports rate limiting.
//

import SwiftUI

struct RateLimitBanner: View {
  let info: ServerRateLimitInfo

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: info.isRejected ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(bannerColor)

      VStack(alignment: .leading, spacing: 2) {
        Text(titleText)
          .font(.caption.weight(.semibold))
          .foregroundStyle(Color.textPrimary)

        if let detail = detailText {
          Text(detail)
            .font(.caption2)
            .foregroundStyle(Color.textSecondary)
        }
      }

      Spacer()
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(bannerColor.opacity(OpacityTier.light))
    .clipShape(RoundedRectangle(cornerRadius: Radius.ml))
    .padding(.horizontal, Spacing.md)
  }

  private var bannerColor: Color {
    info.isRejected ? Color.statusPermission : Color.textTertiary
  }

  private var titleText: String {
    if info.isRejected {
      return "Rate limit reached"
    }
    if let utilization = info.utilization {
      let pct = Int(utilization * 100)
      return "Rate limit warning — \(pct)% used"
    }
    return "Rate limit warning"
  }

  private var detailText: String? {
    if let resetsAt = info.resetsAt {
      return "Resets at \(resetsAt)"
    }
    if info.isRejected {
      return "Requests are being rejected. Please wait."
    }
    return nil
  }
}
