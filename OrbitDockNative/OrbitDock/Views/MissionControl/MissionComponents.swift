import SwiftUI

// MARK: - Section Header

struct MissionSectionHeader: View {
  let title: String
  let icon: String
  var color: Color = .accent
  var count: Int?
  var trailing: String?

  var body: some View {
    HStack(spacing: Spacing.sm_) {
      Image(systemName: icon)
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(color)

      Text(title)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textPrimary)

      if let count {
        Text("\(count)")
          .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
          .foregroundStyle(color)
          .padding(.horizontal, Spacing.xs)
          .padding(.vertical, 1)
          .background(
            color.opacity(OpacityTier.subtle),
            in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
          )
      }

      Spacer()

      if let trailing {
        Text(trailing)
          .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
      }
    }
  }
}

// MARK: - Stat Chip

enum MissionStatChipStyle {
  case dot
  case icon(String)
}

struct MissionStatChip: View {
  let count: UInt32
  let label: String
  let color: Color
  var style: MissionStatChipStyle = .dot

  var body: some View {
    HStack(spacing: Spacing.xs) {
      switch style {
        case .dot:
          Circle()
            .fill(color)
            .frame(width: 5, height: 5)
        case let .icon(name):
          Image(systemName: name)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(count > 0 ? color : Color.textQuaternary)
      }

      Text("\(count)")
        .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
        .foregroundStyle(count > 0 ? color : Color.textQuaternary)

      Text(label)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textTertiary)
    }
  }
}

// MARK: - Issue Filtering

extension [MissionIssueItem] {
  var running: [MissionIssueItem] {
    filter { $0.orchestrationState == .running || $0.orchestrationState == .claimed }
  }

  var queued: [MissionIssueItem] {
    filter { $0.orchestrationState == .queued || $0.orchestrationState == .retryQueued }
  }

  var completed: [MissionIssueItem] {
    filter { $0.orchestrationState == .completed }
  }

  var failed: [MissionIssueItem] {
    filter { $0.orchestrationState == .failed }
  }
}
