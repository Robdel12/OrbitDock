import SwiftUI

private extension View {
  @ViewBuilder
  func controlDeckPillShadow(if condition: Bool) -> some View {
    if condition {
      self
    } else {
      self
    }
  }
}

enum CodexApprovalsReviewer: String, CaseIterable, Identifiable {
  case user
  case guardianSubagent = "guardian_subagent"

  var id: String { rawValue }

  var displayName: String {
    switch self {
      case .user: "You Review"
      case .guardianSubagent: "Guardian Review"
    }
  }

  var compactStatusName: String {
    switch self {
      case .user: "You"
      case .guardianSubagent: "Guardian"
    }
  }

  var icon: String {
    switch self {
      case .user: "person.crop.circle"
      case .guardianSubagent: "shield.lefthalf.filled"
    }
  }

  var color: Color {
    switch self {
      case .user: .textSecondary
      case .guardianSubagent: .autonomyGuarded
    }
  }

  var description: String {
    switch self {
      case .user:
        "Approval requests come straight to you when Codex needs a review decision."
      case .guardianSubagent:
        "Codex routes approval requests through the Guardian reviewer subagent first, so it can gather context and apply a risk-based decision before involving you."
    }
  }

  static func from(rawValue: String?) -> CodexApprovalsReviewer {
    guard let rawValue, let reviewer = CodexApprovalsReviewer(rawValue: rawValue) else {
      return .user
    }
    return reviewer
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
    parse(rawValue) ?? .onRequest
  }

  static func supportedCases(from options: [ControlDeckStatusModuleItem.Option]) -> [CodexApprovalMode] {
    let modes = options.compactMap { parse($0.value) }
    return modes.isEmpty ? allCases : modes
  }

  private static func parse(_ rawValue: String?) -> CodexApprovalMode? {
    guard let rawValue else { return nil }
    let normalized = rawValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
      .replacingOccurrences(of: " ", with: "-")
    if let mode = CodexApprovalMode(rawValue: normalized) {
      return mode
    }
    switch normalized {
      case "onrequest":
        return .onRequest
      case "onfailure":
        return .onFailure
      case "unless-trusted":
        return .untrusted
      default:
        return nil
    }
  }
}

struct CodexApprovalPill: View {
  private enum HelpSection: Hashable {
    case approval
    case reviewer
    case sandbox
  }

  enum PillSize {
    case regular
    case statusBar

    var iconFontSize: CGFloat {
      switch self {
        case .regular: TypeScale.body
        case .statusBar: IconScale.xs
      }
    }

    var textFontSize: CGFloat {
      switch self {
        case .regular: TypeScale.body
        case .statusBar: TypeScale.mini
      }
    }

    var horizontalPadding: CGFloat {
      switch self {
        case .regular: CGFloat(Spacing.md)
        case .statusBar: CGFloat(Spacing.sm_)
      }
    }

    var verticalPadding: CGFloat {
      switch self {
        case .regular: CGFloat(Spacing.sm)
        case .statusBar: CGFloat(Spacing.gap)
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
        case .regular: nil
        case .statusBar: 24
      }
    }
  }

  let currentMode: CodexApprovalMode
  var currentReviewer: CodexApprovalsReviewer = .user
  var currentSandboxPolicy: ServerCodexSandboxPolicy? = nil
  var supportedModes: [CodexApprovalMode] = CodexApprovalMode.allCases
  var size: PillSize = .regular
  var onUpdate: ((CodexApprovalMode) -> Void)?
  var onReviewerUpdate: ((CodexApprovalsReviewer) -> Void)?
  var onSandboxUpdate: ((ServerCodexSandboxPolicy) -> Void)?
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var showPopover = false
  @State private var expandedHelpSections: Set<HelpSection> = []

  private var title: String {
    if size == .statusBar, horizontalSizeClass == .compact { return currentMode.compactStatusName }
    return currentMode.displayName
  }

  private var resolvedSandboxPolicy: ServerCodexSandboxPolicy {
    currentSandboxPolicy ?? ServerCodexSandboxPolicy(
      mode: .workspaceWrite,
      networkAccess: false
    )
  }

  private var currentPolicySummary: String {
    let networkText = resolvedSandboxPolicy.networkAccess ? "Network On" : "Network Off"
    return "\(currentMode.displayName) • \(currentReviewer.displayName) • \(resolvedSandboxPolicy.mode.displayName) (\(networkText))"
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
      let compactLayout = horizontalSizeClass == .compact
      let sandboxPolicy = resolvedSandboxPolicy

      ScrollView {
        VStack(alignment: .leading, spacing: compactLayout ? Spacing.sm : Spacing.md) {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Codex Policy")
              .font(.system(size: TypeScale.subhead, weight: .semibold))
              .foregroundStyle(Color.textPrimary)

            Text("Tune how Codex interrupts, what sandbox it runs in, and who reviews approvals.")
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textSecondary)
              .fixedSize(horizontal: false, vertical: true)

            Text("Current: \(currentPolicySummary)")
              .font(.system(size: TypeScale.micro))
              .foregroundStyle(Color.textTertiary)
              .fixedSize(horizontal: false, vertical: true)
          }

          settingsSection(
            section: .approval,
            title: "Approval",
            detail: "When Codex should pause."
          ) {
            ForEach(supportedModes) { mode in
              selectionRow(
                title: mode.displayName,
                detail: expandedHelpSections.contains(.approval) ? mode.shortDescription : nil,
                icon: mode.icon,
                tint: mode.color,
                isSelected: mode == currentMode
              ) {
                onUpdate?(mode)
                showPopover = false
              }
            }

            dividerRow

            settingsSection(
              section: .reviewer,
              title: "Reviewer",
              detail: "Who gets the first pass."
            ) {
              ForEach(CodexApprovalsReviewer.allCases) { reviewer in
                selectionRow(
                  title: reviewer.displayName,
                  detail: expandedHelpSections.contains(.reviewer) ? reviewer.shortDescription : nil,
                  icon: reviewer.icon,
                  tint: reviewer.color,
                  isSelected: reviewer == currentReviewer
                ) {
                  onReviewerUpdate?(reviewer)
                  showPopover = false
                }
              }
            }
          }

          settingsSection(
            section: .sandbox,
            title: "Sandbox Policy",
            detail: "Which sandbox Codex runs in."
          ) {
            ForEach(ServerCodexSandboxPolicy.controlDeckModes, id: \.self) { mode in
              selectionRow(
                title: mode.displayName,
                detail: expandedHelpSections.contains(.sandbox) ? mode.shortDescription : nil,
                icon: mode.controlDeckIcon,
                tint: sandboxPolicy.mode == mode ? sandboxPolicy.controlDeckTint : mode.controlDeckTint,
                isSelected: sandboxPolicy.mode == mode
              ) {
                onSandboxUpdate?(sandboxPolicy.with(mode: mode, networkAccess: sandboxPolicy.networkAccess))
                showPopover = false
              }
            }

            Button {
              guard sandboxPolicy.mode != .dangerFullAccess else { return }
              onSandboxUpdate?(sandboxPolicy.with(networkAccess: !sandboxPolicy.networkAccess))
              showPopover = false
            } label: {
              HStack(alignment: .center, spacing: Spacing.sm) {
                Image(systemName: sandboxPolicy.networkAccess ? "network" : "network.slash")
                  .font(.system(size: TypeScale.caption, weight: .semibold))
                  .foregroundStyle(sandboxPolicy.controlDeckTint)
                  .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                  Text("Network access")
                    .font(.system(size: TypeScale.body, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)

                  Text(networkStatusText(for: sandboxPolicy))
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(Color.textTertiary)
                }

                Spacer(minLength: Spacing.sm)

                Toggle("", isOn: .constant(sandboxPolicy.networkAccess))
                  .labelsHidden()
                  .allowsHitTesting(false)
              }
              .padding(.vertical, Spacing.xs)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(sandboxPolicy.mode == .dangerFullAccess)
          }
        }
        .padding(compactLayout ? Spacing.md : Spacing.lg)
      }
      #if os(iOS)
        .frame(maxWidth: .infinity)
        .navigationTitle("Codex Policy")
        .navigationBarTitleDisplayMode(.inline)
      #endif
        .ifMacOS { $0.frame(width: 300) }
      .background(Color.backgroundSecondary)
    }
  }

  private func settingsSection<Content: View>(
    section: HelpSection,
    title: String,
    detail: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack(spacing: Spacing.xs) {
          Text(title)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Spacer(minLength: Spacing.xs)

          Button {
            toggleHelp(for: section)
          } label: {
            HStack(spacing: Spacing.xxs) {
              Image(systemName: expandedHelpSections.contains(section) ? "questionmark.circle.fill" : "questionmark.circle")
                .font(.system(size: TypeScale.micro, weight: .semibold))
              Text(expandedHelpSections.contains(section) ? "Hide" : "Help")
                .font(.system(size: TypeScale.micro, weight: .semibold))
            }
            .foregroundStyle(Color.textSecondary)
          }
          .buttonStyle(.plain)
        }

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
    detail: String? = nil,
    icon: String,
    tint: Color,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(alignment: .center, spacing: Spacing.sm) {
        Image(systemName: icon)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 18, height: 18)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(title)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          if let detail, !detail.isEmpty {
            Text(detail)
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textTertiary)
              .fixedSize(horizontal: false, vertical: true)
          }
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

  private var dividerRow: some View {
    Rectangle()
      .fill(Color.panelBorder.opacity(OpacityTier.medium))
      .frame(height: 1)
      .padding(.vertical, Spacing.xxs)
  }

  private func toggleHelp(for section: HelpSection) {
    if expandedHelpSections.contains(section) {
      expandedHelpSections.remove(section)
    } else {
      expandedHelpSections.insert(section)
    }
  }

  private func networkStatusText(for policy: ServerCodexSandboxPolicy) -> String {
    if policy.mode == .dangerFullAccess {
      return "Always allowed in this mode"
    }
    return policy.networkAccess ? "Allowed" : "Blocked"
  }
}

extension ServerCodexSandboxPolicy {
  static var controlDeckModes: [ServerCodexSandboxMode] {
    [
      .dangerFullAccess,
      .workspaceWrite,
      .readOnly,
      .externalSandbox,
    ]
  }

  static var controlDeckOptions: [ServerCodexSandboxPolicy] {
    [
      ServerCodexSandboxPolicy(mode: .dangerFullAccess, networkAccess: true),
      ServerCodexSandboxPolicy(mode: .workspaceWrite, networkAccess: false),
      ServerCodexSandboxPolicy(mode: .workspaceWrite, networkAccess: true),
      ServerCodexSandboxPolicy(mode: .readOnly, networkAccess: false),
      ServerCodexSandboxPolicy(mode: .readOnly, networkAccess: true),
      ServerCodexSandboxPolicy(mode: .externalSandbox, networkAccess: false),
      ServerCodexSandboxPolicy(mode: .externalSandbox, networkAccess: true),
    ]
  }

  func with(mode: ServerCodexSandboxMode, networkAccess: Bool) -> ServerCodexSandboxPolicy {
    ServerCodexSandboxPolicy(
      mode: mode,
      networkAccess: mode == .dangerFullAccess ? true : networkAccess
    )
  }

  func with(networkAccess: Bool) -> ServerCodexSandboxPolicy {
    ServerCodexSandboxPolicy(
      mode: mode,
      networkAccess: mode == .dangerFullAccess ? true : networkAccess
    )
  }

  var controlDeckIcon: String {
    switch mode {
      case .dangerFullAccess: "exclamationmark.triangle.fill"
      case .workspaceWrite: "square.and.pencil"
      case .readOnly: "doc.text.fill"
      case .externalSandbox: "shippingbox.fill"
    }
  }

  var controlDeckTint: Color {
    switch (mode, networkAccess) {
      case (.dangerFullAccess, _): .statusError
      case (.workspaceWrite, true): .autonomyAutonomous
      case (.workspaceWrite, false): .autonomyGuarded
      case (.readOnly, true): .feedbackWarning
      case (.readOnly, false): .textSecondary
      case (.externalSandbox, true): .accent
      case (.externalSandbox, false): .textTertiary
    }
  }
}

extension ServerCodexSandboxMode {
  var controlDeckIcon: String {
    switch self {
      case .dangerFullAccess: "exclamationmark.triangle.fill"
      case .workspaceWrite: "square.and.pencil"
      case .readOnly: "doc.text.fill"
      case .externalSandbox: "shippingbox.fill"
    }
  }

  var controlDeckTint: Color {
    switch self {
      case .dangerFullAccess: .statusError
      case .workspaceWrite: .autonomyAutonomous
      case .readOnly: .feedbackWarning
      case .externalSandbox: .accent
    }
  }

  var shortDescription: String {
    switch self {
      case .dangerFullAccess:
        "No filesystem sandbox. Codex can read, write, and run with full network access."
      case .workspaceWrite:
        "Codex can edit files in your workspace only. System locations stay sandboxed."
      case .readOnly:
        "Codex can inspect files but cannot write changes."
      case .externalSandbox:
        "Codex runs with an externally managed sandbox policy."
    }
  }
}

private extension CodexApprovalMode {
  var shortDescription: String { description }
}

private extension CodexApprovalsReviewer {
  var shortDescription: String { description }
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
        return .none
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
