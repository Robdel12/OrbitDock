import SwiftUI

enum CodexCollaborationMode: String, CaseIterable, Identifiable {
  case `default`
  case plan

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
      case .default: "Default"
      case .plan: "Plan"
    }
  }

  var icon: String {
    switch self {
      case .default: "chevron.left.forwardslash.chevron.right"
      case .plan: "map.fill"
    }
  }

  var color: Color {
    switch self {
      case .default: .providerCodex
      case .plan: .statusQuestion
    }
  }

  var description: String {
    switch self {
      case .default:
        "Standard Codex flow for direct coding, edits, and worker coordination."
      case .plan:
        "Planner-first mode that favors structured thinking and explicit coordination."
    }
  }

  static func from(rawValue: String?, permissionMode: ClaudePermissionMode? = nil) -> CodexCollaborationMode {
    if let rawValue, let mode = CodexCollaborationMode(rawValue: rawValue) {
      return mode
    }
    if permissionMode == .plan {
      return .plan
    }
    return .default
  }

  static func supportedCases(from option: ServerCodexModelOption?) -> [CodexCollaborationMode] {
    guard let option, !option.supportedCollaborationModes.isEmpty else { return allCases }
    let modes = option.supportedCollaborationModes.compactMap(CodexCollaborationMode.init(rawValue:))
    return modes.isEmpty ? allCases : modes
  }
}

enum CodexPersonalityPreset: String, CaseIterable, Identifiable {
  case automatic
  case neutral
  case friendly
  case pragmatic

  var id: String {
    rawValue
  }

  var requestValue: String? {
    switch self {
      case .automatic: nil
      case .neutral: "none"
      case .friendly: "friendly"
      case .pragmatic: "pragmatic"
    }
  }

  var displayName: String {
    switch self {
      case .automatic: "Auto"
      case .neutral: "Neutral"
      case .friendly: "Friendly"
      case .pragmatic: "Pragmatic"
    }
  }

  var icon: String {
    switch self {
      case .automatic: "circle.dashed"
      case .neutral: "text.bubble"
      case .friendly: "hand.wave.fill"
      case .pragmatic: "hammer.fill"
    }
  }

  var color: Color {
    switch self {
      case .automatic: .textQuaternary
      case .neutral: .statusReply
      case .friendly: .feedbackPositive
      case .pragmatic: .feedbackCaution
    }
  }

  var description: String {
    switch self {
      case .automatic:
        "Use the model's default communication style."
      case .neutral:
        "Keep responses straightforward without a stronger style layer."
      case .friendly:
        "Make the assistant warmer and a little more conversational."
      case .pragmatic:
        "Bias toward concise, practical guidance and action."
    }
  }

  static func from(serverValue: String?) -> CodexPersonalityPreset {
    switch serverValue {
      case "none":
        .neutral
      case "friendly":
        .friendly
      case "pragmatic":
        .pragmatic
      default:
        .automatic
    }
  }
}

enum CodexServiceTierPreset: String, CaseIterable, Identifiable {
  case automatic
  case fast
  case flex

  var id: String {
    rawValue
  }

  var requestValue: String? {
    switch self {
      case .automatic: nil
      case .fast, .flex: rawValue
    }
  }

  var displayName: String {
    switch self {
      case .automatic: "Auto"
      case .fast: "Fast"
      case .flex: "Flex"
    }
  }

  var icon: String {
    switch self {
      case .automatic: "circle.dashed"
      case .fast: "bolt.fill"
      case .flex: "dial.high"
    }
  }

  var color: Color {
    switch self {
      case .automatic: .textQuaternary
      case .fast: .feedbackPositive
      case .flex: .feedbackCaution
    }
  }

  var description: String {
    switch self {
      case .automatic:
        "Let Codex choose the service tier for this session."
      case .fast:
        "Prefer the fast tier when it is available."
      case .flex:
        "Prefer the flex tier when the session can wait a little."
    }
  }

  static func from(serverValue: String?) -> CodexServiceTierPreset {
    switch serverValue {
      case "fast":
        .fast
      case "flex":
        .flex
      default:
        .automatic
    }
  }

  static func supportedCases(from option: ServerCodexModelOption?) -> [CodexServiceTierPreset] {
    guard let option, !option.supportedServiceTiers.isEmpty else { return allCases }
    let presets = option.supportedServiceTiers.compactMap(CodexServiceTierPreset.init(rawValue:))
    return [.automatic] + presets.filter { $0 != .automatic }
  }
}

struct CodexModePill: View {
  enum PillSize {
    case regular
    case statusBar

    var iconFontSize: CGFloat {
      self == .statusBar ? 9 : TypeScale.body
    }

    var textFontSize: CGFloat {
      self == .statusBar ? 10 : TypeScale.body
    }

    var horizontalPadding: CGFloat {
      self == .statusBar ? 6 : CGFloat(Spacing.md)
    }

    var verticalPadding: CGFloat {
      self == .statusBar ? 3 : CGFloat(Spacing.sm)
    }

    var spacing: CGFloat {
      self == .statusBar ? 3 : CGFloat(Spacing.xs)
    }

    var height: CGFloat? {
      self == .statusBar ? 20 : nil
    }
  }

  let currentMode: CodexCollaborationMode
  var supportedModes: [CodexCollaborationMode] = CodexCollaborationMode.allCases
  var size: PillSize = .regular
  var onUpdate: ((CodexCollaborationMode) -> Void)?
  @State private var showPopover = false

  var body: some View {
    Button {
      showPopover.toggle()
    } label: {
      HStack(spacing: size.spacing) {
        Image(systemName: currentMode.icon)
          .font(.system(size: size.iconFontSize, weight: .semibold))
        Text(currentMode.displayName)
          .font(.system(size: size.textFontSize, weight: .semibold))
      }
      .foregroundStyle(currentMode.color)
      .padding(.horizontal, size.horizontalPadding)
      .padding(.vertical, size.verticalPadding)
      .frame(height: size.height)
      .background(currentMode.color.opacity(OpacityTier.light), in: Capsule())
    }
    .buttonStyle(.plain)
    .fixedSize()
    .platformPopover(isPresented: $showPopover) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        Text("Collaboration")
          .font(.system(size: TypeScale.subhead, weight: .semibold))
          .foregroundStyle(Color.textPrimary)

        ForEach(supportedModes) { mode in
          Button {
            onUpdate?(mode)
            showPopover = false
          } label: {
            HStack(alignment: .top, spacing: Spacing.sm) {
              Image(systemName: mode.icon)
                .font(.system(size: TypeScale.caption, weight: .semibold))
                .foregroundStyle(mode.color)
                .frame(width: 18, height: 18)

              VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(mode.displayName)
                  .font(.system(size: TypeScale.body, weight: .semibold))
                  .foregroundStyle(Color.textPrimary)

                Text(mode.description)
                  .font(.system(size: TypeScale.caption))
                  .foregroundStyle(Color.textTertiary)
                  .fixedSize(horizontal: false, vertical: true)
              }

              Spacer(minLength: Spacing.sm)

              if mode == currentMode {
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
      .ifMacOS { $0.frame(width: 280) }
      .background(Color.backgroundSecondary)
    }
  }
}
