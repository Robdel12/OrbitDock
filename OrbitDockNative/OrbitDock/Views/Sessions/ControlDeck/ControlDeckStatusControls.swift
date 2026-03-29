import SwiftUI

private extension View {
  @ViewBuilder
  func controlDeckPillShadow(if condition: Bool) -> some View {
    if condition {
      self.themeShadow(Shadow.sm)
    } else {
      self
    }
  }
}

enum CodexApprovalMode: String, CaseIterable, Identifiable {
  case untrusted
  case onFailure = "on-failure"
  case onRequest = "on-request"
  case never

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
      case .untrusted: "Review Writes"
      case .onFailure: "Ask If Blocked"
      case .onRequest: "Ask When Useful"
      case .never: "Don't Interrupt"
    }
  }

  var compactStatusName: String {
    switch self {
      case .untrusted: "Writes"
      case .onFailure: "Blocked"
      case .onRequest: "Useful"
      case .never: "Quiet"
    }
  }

  var icon: String {
    switch self {
      case .untrusted: "lock.shield.fill"
      case .onFailure: "shield.lefthalf.filled"
      case .onRequest: "checkmark.shield.fill"
      case .never: "bolt.fill"
    }
  }

  var color: Color {
    switch self {
      case .untrusted: .autonomyLocked
      case .onFailure: .autonomyGuarded
      case .onRequest: .autonomyAutonomous
      case .never: .autonomyFullAuto
    }
  }

  var description: String {
    switch self {
      case .untrusted:
        "Reads can continue quietly, but Codex stops and asks before it edits files, writes data, or runs commands."
      case .onFailure:
        "Codex tries the work inside the sandbox first. You only get interrupted when the sandbox blocks what it wants to do."
      case .onRequest:
        "Codex can choose to pause and ask when it thinks a handoff is useful, even if the sandbox has not blocked the work."
      case .never:
        "Codex will not stop to ask for approval. Use this only when you intentionally want uninterrupted execution."
    }
  }

  static func from(rawValue: String?) -> CodexApprovalMode {
    guard let rawValue, let mode = CodexApprovalMode(rawValue: rawValue) else {
      return .onRequest
    }
    return mode
  }

  static func supportedCases(from options: [ControlDeckStatusModuleItem.Option]) -> [CodexApprovalMode] {
    let modes = options.compactMap { CodexApprovalMode(rawValue: $0.value) }
    return modes.isEmpty ? allCases : modes
  }
}

struct CodexApprovalPill: View {
  enum PillSize {
    case regular
    case statusBar

    var iconFontSize: CGFloat {
      switch self {
        case .regular: TypeScale.body
        case .statusBar:
          #if os(iOS)
            IconScale.xs
          #else
            IconScale.sm
          #endif
      }
    }

    var textFontSize: CGFloat {
      switch self {
        case .regular: TypeScale.body
        case .statusBar:
          #if os(iOS)
            TypeScale.mini
          #else
            TypeScale.micro
          #endif
      }
    }

    var horizontalPadding: CGFloat {
      switch self {
        case .regular: CGFloat(Spacing.md)
        case .statusBar:
          #if os(iOS)
            CGFloat(Spacing.sm_)
          #else
            CGFloat(Spacing.sm)
          #endif
      }
    }

    var verticalPadding: CGFloat {
      switch self {
        case .regular: CGFloat(Spacing.sm)
        case .statusBar:
          #if os(iOS)
            CGFloat(Spacing.gap)
          #else
            CGFloat(Spacing.xs)
          #endif
      }
    }

    var spacing: CGFloat {
      switch self {
        case .regular: CGFloat(Spacing.xs)
        case .statusBar: CGFloat(Spacing.xs)
      }
    }

    var height: CGFloat? {
      switch self {
        case .regular:
          nil
        case .statusBar:
          #if os(iOS)
            24
          #else
            20
          #endif
      }
    }
  }

  let currentMode: CodexApprovalMode
  var supportedModes: [CodexApprovalMode] = CodexApprovalMode.allCases
  var size: PillSize = .regular
  var onUpdate: ((CodexApprovalMode) -> Void)?
  @State private var showPopover = false

  private var title: String {
    #if os(iOS)
      if size == .statusBar { return currentMode.compactStatusName }
    #endif
    return currentMode.displayName
  }

  var body: some View {
    Button {
      showPopover.toggle()
    } label: {
      HStack(spacing: size.spacing) {
        Image(systemName: currentMode.icon)
          .font(.system(size: size.iconFontSize, weight: .semibold))
        Text(title)
          .font(.system(size: size.textFontSize, weight: .semibold))
      }
      .foregroundStyle(currentMode.color)
      .padding(.horizontal, size.horizontalPadding)
      .padding(.vertical, size.verticalPadding)
      .frame(height: size.height)
      .background(currentMode.color.opacity(OpacityTier.light), in: Capsule())
      .overlay(
        Capsule()
          .strokeBorder(currentMode.color.opacity(OpacityTier.medium), lineWidth: 0.75)
      )
      .controlDeckPillShadow(if: size == .regular)
    }
    .buttonStyle(.plain)
    .fixedSize()
    .platformPopover(isPresented: $showPopover) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Codex Approvals")
              .font(.system(size: TypeScale.subhead, weight: .semibold))
              .foregroundStyle(Color.textPrimary)

            Text("Choose when Codex should pause for approval.")
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          settingsSection(
            title: "When Codex Interrupts You",
            detail: "This is the provider approval policy."
          ) {
            ForEach(supportedModes) { mode in
              selectionRow(
                title: mode.displayName,
                detail: mode.description,
                icon: mode.icon,
                tint: mode.color,
                isSelected: mode == currentMode
              ) {
                onUpdate?(mode)
                showPopover = false
              }
            }
          }
        }
        .padding(Spacing.lg)
      }
      #if os(iOS)
        .frame(maxWidth: .infinity)
        .navigationTitle("Approval")
        .navigationBarTitleDisplayMode(.inline)
      #endif
        .ifMacOS { $0.frame(width: 320) }
      .background(Color.backgroundSecondary)
    }
  }

  private func settingsSection<Content: View>(
    title: String,
    detail: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(title)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textPrimary)

        Text(detail)
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        content()
      }
    }
  }

  private func selectionRow(
    title: String,
    detail: String,
    icon: String,
    tint: Color,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        Image(systemName: icon)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 18, height: 18)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(title)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text(detail)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: Spacing.sm)

        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.accent)
        }
      }
      .padding(.vertical, Spacing.xs)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

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
  @State private var showPopover = false

  private var title: String {
    #if os(iOS)
      if size == .statusBar {
        switch currentLevel {
          case .locked: return "You"
          case .guarded: return "Sandbox"
          case .autonomous: return "OrbitDock"
          case .open: return "OrbitDock+"
          case .fullAuto: return "Codex"
          case .unrestricted: return "None"
        }
      }
    #endif
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

extension EffortLevel {
  static func fromControlDeckValue(_ value: String?) -> EffortLevel {
    guard let value, let level = EffortLevel(rawValue: value) else {
      return .default
    }
    return level
  }

  static func supportedControlDeckCases(
    from options: [ControlDeckStatusModuleItem.Option]
  ) -> [EffortLevel] {
    let levels = options.compactMap { option in
      EffortLevel(rawValue: option.value)
    }
    return levels.isEmpty ? concreteCases : levels
  }
}

struct EffortPill: View {
  let currentLevel: EffortLevel
  var supportedLevels: [EffortLevel] = EffortLevel.concreteCases
  var size: CodexApprovalPill.PillSize = .regular
  var onUpdate: ((EffortLevel) -> Void)?
  @State private var showPopover = false

  private var title: String {
    #if os(iOS)
      if size == .statusBar, currentLevel == .default {
        return "Auto"
      }
    #endif
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
      #if os(iOS)
        .frame(maxWidth: .infinity)
        .navigationTitle("Reasoning Effort")
        .navigationBarTitleDisplayMode(.inline)
      #endif
        .ifMacOS { $0.frame(width: 320) }
        .background(Color.backgroundSecondary)
    }
  }
}
