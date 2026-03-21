import SwiftUI

struct ContextGaugeCompact: View {
  let stats: TranscriptUsageStats

  private var progressColor: Color {
    if stats.contextPercentage > 0.9 { return .statusError }
    if stats.contextPercentage > 0.7 { return .feedbackCaution }
    return .accent
  }

  var body: some View {
    HStack(spacing: Spacing.sm_) {
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
            .fill(Color.primary.opacity(0.1))

          RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
            .fill(progressColor)
            .frame(width: geo.size.width * stats.contextPercentage)
        }
      }
      .frame(width: 32, height: 4)

      Text("\(Int(stats.contextPercentage * 100))%")
        .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
        .foregroundStyle(progressColor)
    }
  }
}
