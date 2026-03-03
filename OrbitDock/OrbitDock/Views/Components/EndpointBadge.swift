import SwiftUI

struct EndpointBadge: View {
  let endpointName: String?
  var isDefault: Bool = false

  private var label: String {
    let trimmed = endpointName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty {
      return "Endpoint"
    }
    return trimmed
  }

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: isDefault ? "star.fill" : "network")
        .font(.system(size: 8, weight: .semibold))
      Text(label)
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .lineLimit(1)
    }
    .foregroundStyle(isDefault ? Color.accent : Color.textTertiary)
    .padding(.horizontal, 7)
    .padding(.vertical, Spacing.gap)
    .background(
      Capsule()
        .fill(isDefault ? Color.accent.opacity(OpacityTier.light) : Color.backgroundTertiary)
    )
  }
}
