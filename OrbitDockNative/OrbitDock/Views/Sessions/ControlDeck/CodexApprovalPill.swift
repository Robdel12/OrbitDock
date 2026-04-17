import SwiftUI

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
