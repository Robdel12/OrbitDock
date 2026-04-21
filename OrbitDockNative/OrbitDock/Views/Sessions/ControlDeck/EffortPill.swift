import SwiftUI

extension EffortLevel {
  static func fromControlDeckValue(_ value: String?) -> EffortLevel {
    parse(value) ?? .default
  }

  static func supportedControlDeckCases(
    from options: [ControlDeckStatusModuleItem.Option]
  ) -> [EffortLevel] {
    let levels = options.compactMap { option in parse(option.value) }
    return levels.isEmpty ? concreteCases : levels
  }

  private static func parse(_ rawValue: String?) -> EffortLevel? {
    guard let rawValue else { return nil }
    let normalized = rawValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "")
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: " ", with: "")

    switch normalized {
      case "":
        return .default
      case "auto", "default":
        return .default
      case "none":
        return EffortLevel.none
      case "minimal":
        return .minimal
      case "low":
        return .low
      case "medium":
        return .medium
      case "high":
        return .high
      case "xhigh", "extrahigh", "max":
        return .xhigh
      default:
        return nil
    }
  }
}

struct EffortPill: View {
  let currentLevel: EffortLevel
  var supportedLevels: [EffortLevel] = EffortLevel.concreteCases
  var size: CodexApprovalPill.PillSize = .regular
  var onUpdate: ((EffortLevel) -> Void)?
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var showPopover = false

  private var title: String {
    if size == .statusBar, horizontalSizeClass == .compact, currentLevel == .default {
      return "Auto"
    }
    return currentLevel.displayName
  }

  var body: some View {
    Button {
      showPopover.toggle()
    } label: {
      HStack(spacing: size.spacing) {
        Image(systemName: currentLevel.icon)
          .font(.system(size: size.iconFontSize, weight: .semibold))
        Text(title)
          .font(.system(size: size.textFontSize, weight: .semibold))
      }
      .foregroundStyle(currentLevel == .default ? Color.accent : currentLevel.color)
      .padding(.horizontal, size.horizontalPadding)
      .padding(.vertical, size.verticalPadding)
      .frame(height: size.height)
      .background((currentLevel == .default ? Color.accent : currentLevel.color).opacity(OpacityTier.light), in: Capsule())
      .overlay(
        Capsule()
          .strokeBorder((currentLevel == .default ? Color.accent : currentLevel.color).opacity(OpacityTier.medium), lineWidth: 0.75)
      )
      .controlDeckPillShadow(if: size == .regular)
    }
    .buttonStyle(.plain)
    .fixedSize()
    .platformPopover(isPresented: $showPopover) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Reasoning Effort")
              .font(.system(size: TypeScale.subhead, weight: .semibold))
              .foregroundStyle(Color.textPrimary)

            Text("Controls how much extra reasoning time Codex spends before responding.")
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          ForEach(supportedLevels) { level in
            Button {
              onUpdate?(level)
              showPopover = false
            } label: {
              HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: level.icon)
                  .font(.system(size: TypeScale.caption, weight: .semibold))
                  .foregroundStyle(level.color)
                  .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                  HStack(spacing: Spacing.xs) {
                    Text(level.displayName)
                      .font(.system(size: TypeScale.body, weight: .semibold))
                      .foregroundStyle(Color.textPrimary)

                    if !level.speedLabel.isEmpty {
                      Text(level.speedLabel)
                        .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.textTertiary)
                        .padding(.horizontal, Spacing.xs)
                        .padding(.vertical, 1)
                        .background(Color.backgroundPrimary, in: Capsule())
                    }
                  }

                  Text(level.description)
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Spacing.sm)

                if level == currentLevel {
                  Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: TypeScale.caption, weight: .semibold))
                    .foregroundStyle(Color.accent)
                }
              }
              .padding(.vertical, Spacing.xs)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(Spacing.lg)
      }
      .platformSheetNavigationTitle("Reasoning Effort")
        .ifMacOS { $0.frame(width: 320) }
        .background(Color.backgroundSecondary)
    }
  }
}
