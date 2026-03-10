import SwiftUI

struct HeaderCompactPresentation: Equatable {
  let statusColor: Color
  let statusIcon: String
  let statusLabel: String
  let modelSummary: String

  static func build(
    workStatus: Session.WorkStatus,
    provider: Provider,
    model: String?,
    effort: String?
  ) -> HeaderCompactPresentation {
    HeaderCompactPresentation(
      statusColor: statusColor(for: workStatus),
      statusIcon: statusIcon(for: workStatus),
      statusLabel: statusLabel(for: workStatus),
      modelSummary: modelSummary(provider: provider, model: model, effort: effort)
    )
  }

  static func effortLabel(for effort: String?) -> String? {
    guard let trimmed = effort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !trimmed.isEmpty,
          trimmed != "default"
    else { return nil }
    return trimmed.capitalized
  }

  static func effortColor(for effort: String?) -> Color {
    guard let trimmed = effort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !trimmed.isEmpty
    else { return .textSecondary }

    switch trimmed {
      case "low": return .effortLow
      case "medium": return .effortMedium
      case "high": return .effortHigh
      case "max": return .effortXHigh
      default: return .textSecondary
    }
  }

  private static func statusColor(for workStatus: Session.WorkStatus) -> Color {
    switch workStatus {
      case .working: .statusWorking
      case .waiting: .statusReply
      case .permission: .statusPermission
      case .unknown: .statusWorking.opacity(0.6)
    }
  }

  private static func statusIcon(for workStatus: Session.WorkStatus) -> String {
    switch workStatus {
      case .working: "bolt.fill"
      case .waiting: "clock.fill"
      case .permission: "lock.fill"
      case .unknown: "circle.fill"
    }
  }

  private static func statusLabel(for workStatus: Session.WorkStatus) -> String {
    switch workStatus {
      case .working: "Working"
      case .waiting: "Waiting"
      case .permission: "Approval"
      case .unknown: "Active"
    }
  }

  private static func modelSummary(provider: Provider, model: String?, effort: String?) -> String {
    let raw = model?.trimmingCharacters(in: .whitespacesAndNewlines)
    let label: String = if let raw, !raw.isEmpty {
      raw
    } else {
      provider.rawValue
    }
    let effortSuffix = effortLabel(for: effort).map { " • \($0)" } ?? ""
    let combined = "\(label)\(effortSuffix)"
    guard combined.count > 18 else { return combined }
    return String(combined.prefix(17)) + "..."
  }
}

struct HeaderCompactStatusBadge: View {
  let presentation: HeaderCompactPresentation

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: presentation.statusIcon)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(presentation.statusColor)

      Text(presentation.statusLabel)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(1)

      Rectangle()
        .fill(Color.surfaceBorder)
        .frame(width: 1, height: 11)

      Text(presentation.modelSummary)
        .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundTertiary.opacity(0.58))
    )
    .themeShadow(Shadow.md)
  }
}
