import SwiftUI

struct PendingPanelInlineHeader: View {
  let title: String
  let statusText: String
  let promptCountText: String?
  let header: ApprovalHeaderConfig
  let modeColor: Color
  let isExpanded: Bool
  let isHovering: Bool
  let onToggle: () -> Void
  let onHoverChanged: (Bool) -> Void

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: Spacing.sm_) {
        Image(systemName: header.iconName)
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(header.iconTint)
          .frame(width: 16, height: 16)
          .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              .fill(header.iconTint.opacity(OpacityTier.light))
          )

        Text(title)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textPrimary)

        PendingPanelHeaderChip(text: statusText, tint: modeColor)

        if let promptCountText {
          PendingPanelHeaderChip(text: promptCountText, tint: Color.statusQuestion)
        }

        Spacer(minLength: 0)

        Image(systemName: "chevron.right")
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(Color.textQuaternary)
          .frame(width: 16, height: 16)
          .background(Circle().fill(Color.surfaceHover.opacity(OpacityTier.subtle)))
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .animation(Motion.snappy, value: isExpanded)
      }
      .padding(.horizontal, Spacing.md_)
      .padding(.vertical, Spacing.xs)
      .background(
        isHovering ? Color.surfaceHover : modeColor.opacity(OpacityTier.tint)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover(perform: onHoverChanged)
  }
}

struct PendingPanelHeaderChip: View {
  let text: String
  let tint: Color

  var body: some View {
    if !text.isEmpty {
      Text(text)
        .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
        .foregroundStyle(tint)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .background(
          Capsule().fill(tint.opacity(OpacityTier.light))
        )
    }
  }
}

struct PendingCommandCodeBlock: View {
  let command: String
  let modeColor: Color
  let isCompactLayout: Bool

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      Text(verbatim: command)
        .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.caption, weight: .regular, design: .monospaced))
        .foregroundStyle(Color.textPrimary)
        .lineSpacing(isCompactLayout ? 2 : 3)
        .fixedSize(horizontal: true, vertical: true)
        .multilineTextAlignment(.leading)
        .textSelection(.enabled)
        .padding(.horizontal, isCompactLayout ? Spacing.sm : Spacing.md_)
        .padding(.vertical, isCompactLayout ? Spacing.xs : Spacing.sm_)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: isCompactLayout ? Radius.sm : Radius.md, style: .continuous)
        .fill(Color.backgroundCode)
        .overlay(
          RoundedRectangle(cornerRadius: isCompactLayout ? Radius.sm : Radius.md, style: .continuous)
            .fill(modeColor.opacity(OpacityTier.tint))
        )
    )
    .overlay(
      RoundedRectangle(cornerRadius: isCompactLayout ? Radius.sm : Radius.md, style: .continuous)
        .strokeBorder(modeColor.opacity(OpacityTier.light), lineWidth: 0.5)
    )
  }
}

struct PendingCommandChainRow: View {
  let index: Int
  let segment: ApprovalShellSegment
  let modeColor: Color
  let isCompactLayout: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: isCompactLayout ? Spacing.xxs : Spacing.sm_) {
      HStack(spacing: Spacing.xs) {
        Text("\(index)")
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(modeColor)
          .frame(width: 12, height: 12)
          .background(
            Circle()
              .fill(modeColor.opacity(OpacityTier.light))
          )

        if let operatorText = normalizedLeadingOperator, index > 1 {
          let operatorHint = ApprovalPermissionPreviewHelpers.operatorLabel(operatorText) ?? "then"
          Text("[\(operatorText)] \(operatorHint)")
            .font(.system(size: TypeScale.mini, weight: .medium))
            .foregroundStyle(Color.textTertiary)
        } else {
          Text("Run first")
            .font(.system(size: TypeScale.mini, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
        }

        Spacer(minLength: 0)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        Text(verbatim: segment.command)
          .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.caption, weight: .regular, design: .monospaced))
          .foregroundStyle(Color.textPrimary)
          .lineSpacing(isCompactLayout ? 2 : 3)
          .fixedSize(horizontal: true, vertical: true)
          .multilineTextAlignment(.leading)
          .textSelection(.enabled)
          .padding(.horizontal, isCompactLayout ? Spacing.sm : Spacing.md_)
          .padding(.vertical, isCompactLayout ? Spacing.xs : Spacing.sm_)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .fill(Color.backgroundCode)
          .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              .fill(modeColor.opacity(OpacityTier.tint))
          )
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .strokeBorder(modeColor.opacity(OpacityTier.light), lineWidth: 0.5)
      )
    }
  }

  private var normalizedLeadingOperator: String? {
    segment.leadingOperator?.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct PendingRiskFindingsSection: View {
  let findings: [String]
  let tint: Color
  let highlightsBackground: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
        HStack(alignment: .top, spacing: Spacing.xs) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(tint)
          Text(finding)
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
        }
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(highlightsBackground ? Color.statusError.opacity(OpacityTier.tint) : Color.clear)
    )
  }
}

struct PendingInfoHintRow: View {
  let iconName: String
  let iconColor: Color
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.xs) {
      Image(systemName: iconName)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(iconColor)
      Text(text)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.leading)
    }
  }
}

struct PendingDenyReasonField: View {
  let text: Binding<String>

  var body: some View {
    TextField("Deny reason", text: text)
      .textFieldStyle(.plain)
      .font(.system(size: TypeScale.caption))
      .foregroundStyle(Color.textPrimary)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.sm_)
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(Color.backgroundCode)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .strokeBorder(Color.feedbackNegative.opacity(OpacityTier.subtle), lineWidth: 1)
      )
  }
}
