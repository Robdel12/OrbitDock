import SwiftUI

extension AutonomyLevel {
  static func fromAutoReviewValue(_ value: String?) -> AutonomyLevel? {
    switch value {
      case "locked": .locked
      case "guarded": .guarded
      case "autonomous": .autonomous
      case "open": .open
      case "full_auto": .fullAuto
      case "unrestricted": .unrestricted
      default: nil
    }
  }

  static func supportedAutoReviewCases(
    from options: [ControlDeckStatusModuleItem.Option]
  ) -> [AutonomyLevel] {
    let levels = options.compactMap { option in
      fromAutoReviewValue(option.value)
    }
    return levels.isEmpty ? allCases : levels
  }
}

struct CodexAutoReviewPill: View {
  let currentLevel: AutonomyLevel
  var supportedLevels: [AutonomyLevel] = AutonomyLevel.allCases
  var size: CodexApprovalPill.PillSize = .regular
  var onUpdate: ((AutonomyLevel) -> Void)?
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var showPopover = false

  private var title: String {
    if size == .statusBar, horizontalSizeClass == .compact {
      switch currentLevel {
        case .locked: return "You"
        case .guarded: return "Sandbox"
        case .autonomous: return "OrbitDock"
        case .open: return "OrbitDock+"
        case .fullAuto: return "Codex"
        case .unrestricted: return "None"
      }
    }
    return currentLevel.controlDeckAutoReviewLabel
  }

  var body: some View {
    Button {
      showPopover.toggle()
    } label: {
      HStack(spacing: size.spacing) {
        Image(systemName: currentLevel.autoReviewStatusIcon)
          .font(.system(size: size.iconFontSize, weight: .semibold))
        Text(title)
          .font(.system(size: size.textFontSize, weight: .semibold))
      }
      .foregroundStyle(currentLevel.color)
      .padding(.horizontal, size.horizontalPadding)
      .padding(.vertical, size.verticalPadding)
      .frame(height: size.height)
      .background(currentLevel.color.opacity(OpacityTier.light), in: Capsule())
      .overlay(
        Capsule()
          .strokeBorder(currentLevel.color.opacity(OpacityTier.medium), lineWidth: 0.75)
      )
      .controlDeckPillShadow(if: size == .regular)
    }
    .buttonStyle(.plain)
    .fixedSize()
    .platformPopover(isPresented: $showPopover) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("If Work Gets Blocked")
              .font(.system(size: TypeScale.subhead, weight: .semibold))
              .foregroundStyle(Color.textPrimary)

            Text("Choose who gets the first chance to handle blocked work before it comes back to you.")
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
                Image(systemName: level.autoReviewStatusIcon)
                  .font(.system(size: TypeScale.caption, weight: .semibold))
                  .foregroundStyle(level.color)
                  .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                  Text(level.controlDeckAutoReviewLabel)
                    .font(.system(size: TypeScale.body, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)

                  Text(level.controlDeckAutoReviewSummary)
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
      #if os(iOS)
        .frame(maxWidth: .infinity)
        .navigationTitle("Auto Review")
        .navigationBarTitleDisplayMode(.inline)
      #endif
        .ifMacOS { $0.frame(width: 340) }
        .background(Color.backgroundSecondary)
    }
  }
}
