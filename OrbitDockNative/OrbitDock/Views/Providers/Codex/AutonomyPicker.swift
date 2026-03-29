//
//  AutonomyPicker.swift
//  OrbitDock
//
//  Shared autonomy level enum and compact picker for Codex sessions.
//  Used in NewCodexSessionSheet (creation) and SessionDetailView (live control).
//

import SwiftUI

// MARK: - Autonomy Level

enum AutonomyLevel: String, CaseIterable, Identifiable {
  case locked
  case guarded
  case autonomous
  case fullAuto
  case open
  case unrestricted

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
      case .locked: "Locked"
      case .guarded: "Guarded"
      case .autonomous: "Autonomous"
      case .open: "Open"
      case .fullAuto: "Full Auto"
      case .unrestricted: "Unrestricted"
    }
  }

  var icon: String {
    switch self {
      case .locked: "lock.shield.fill"
      case .guarded: "shield.lefthalf.filled"
      case .autonomous: "bolt.shield.fill"
      case .open: "lock.open.fill"
      case .fullAuto: "bolt.fill"
      case .unrestricted: "exclamationmark.triangle.fill"
    }
  }

  var description: String {
    switch self {
      case .locked: "Only known-safe reads auto-approve"
      case .guarded: "Sandbox tries everything, asks on failure"
      case .autonomous: "Model decides, safe commands auto-approve"
      case .open: "Model decides, no sandbox restrictions"
      case .fullAuto: "Everything runs in sandbox, never asks"
      case .unrestricted: "No sandbox, no approvals"
    }
  }

  var color: Color {
    switch self {
      case .locked: .autonomyLocked
      case .guarded: .autonomyGuarded
      case .autonomous: .autonomyAutonomous
      case .open: .autonomyOpen
      case .fullAuto: .autonomyFullAuto
      case .unrestricted: .autonomyUnrestricted
    }
  }

  var isDefault: Bool {
    self == .autonomous
  }

  var isSandboxed: Bool {
    switch self {
      case .locked, .guarded, .autonomous, .fullAuto: true
      case .open, .unrestricted: false
    }
  }

  /// Human-readable approval behavior
  var approvalBehavior: String {
    switch self {
      case .locked: "Asks for writes & commands"
      case .guarded: "Asks when sandbox fails"
      case .autonomous: "Asks when model is unsure"
      case .open: "Asks when model is unsure"
      case .fullAuto: "Never asks"
      case .unrestricted: "Never asks"
    }
  }

  var autoReviewStatusLabel: String {
    switch self {
      case .locked: "Safe Reads"
      case .guarded: "Sandbox First"
      case .autonomous, .open: "Auto Review"
      case .fullAuto: "No Prompts"
      case .unrestricted: "Unrestricted"
    }
  }

  var controlDeckAutoReviewLabel: String {
    switch self {
      case .locked: "You Review It"
      case .guarded: "Sandbox Retries First"
      case .autonomous: "OrbitDock Can Decide"
      case .open: "OrbitDock Decides Openly"
      case .fullAuto: "Codex Keeps Going"
      case .unrestricted: "Nothing Stops It"
    }
  }

  var autoReviewStatusIcon: String {
    switch self {
      case .locked: "lock.shield.fill"
      case .guarded: "shield.lefthalf.filled"
      case .autonomous, .open: "bolt.shield.fill"
      case .fullAuto: "bolt.fill"
      case .unrestricted: "exclamationmark.triangle.fill"
    }
  }

  var autoReviewCardTitle: String {
    switch self {
      case .locked: "Known-safe reads can pass quietly"
      case .guarded: "Codex tries the sandbox before it asks"
      case .autonomous: "Codex can review requests on your behalf"
      case .open: "Codex can review requests without sandbox limits"
      case .fullAuto: "This session is running without interactive approvals"
      case .unrestricted: "Codex is operating without a safety rail"
    }
  }

  var autoReviewCardSummary: String {
    switch self {
      case .locked:
        "Low-risk reads can continue automatically, but writes and commands still come back through the normal approval flow."
      case .guarded:
        "Most work stays inside the sandbox. OrbitDock only needs to surface the request when the sandbox blocks the action."
      case .autonomous:
        "Codex weighs risk and can approve or deny a request without interrupting you when it has enough confidence."
      case .open:
        "Codex is still making the approval call, but it is doing that work without sandbox restrictions, so this mode deserves extra attention."
      case .fullAuto:
        "Approval UI becomes read-only context here. Codex runs directly inside the configured sandbox and will not pause for confirmation."
      case .unrestricted:
        "There is no sandbox and no approval pause. OrbitDock can only show policy context after the fact, so treat this as a deliberate high-trust mode."
    }
  }

  var controlDeckAutoReviewSummary: String {
    switch self {
      case .locked:
        "Blocked work always comes back to you. OrbitDock does not try to resolve it on your behalf."
      case .guarded:
        "OrbitDock lets the sandbox try first. You only see the prompt when the sandbox cannot satisfy the request."
      case .autonomous:
        "OrbitDock can approve or deny some blocked work for Codex when it has enough confidence, so you get interrupted less often."
      case .open:
        "OrbitDock can still make that decision for Codex, but it is doing it without sandbox restrictions."
      case .fullAuto:
        "Codex stays in motion without approval interruptions. You are choosing audit context over live approval."
      case .unrestricted:
        "There is no sandbox and no approval stop. Nothing blocks the agent before it acts."
    }
  }

  var autoReviewHighlights: [String] {
    switch self {
      case .locked:
        [
          "Read-only work can stay fast and uninterrupted",
          "Edits, writes, and shell actions still require explicit review",
        ]
      case .guarded:
        [
          "The sandbox absorbs most routine risk automatically",
          "Requests only escalate when the model hits a real boundary",
        ]
      case .autonomous:
        [
          "Higher-confidence requests can be resolved without a handoff",
          "Anything uncertain still lands back in the regular approval UI",
        ]
      case .open:
        [
          "Auto review is still active in this mode",
          "Because sandboxing is off, the model's risk judgment matters more",
        ]
      case .fullAuto:
        [
          "You will not get an approval interruption for individual actions",
          "This panel is best used as policy and audit context",
        ]
      case .unrestricted:
        [
          "Nothing is sandboxed and nothing is approval-gated",
          "Use this only when you intentionally want maximum autonomy",
        ]
    }
  }

  var approvalPolicy: String? {
    switch self {
      case .locked: "untrusted"
      case .guarded: "on-failure"
      case .autonomous: "on-request"
      case .open: "on-request"
      case .fullAuto: "never"
      case .unrestricted: "never"
    }
  }

  var sandboxMode: String? {
    switch self {
      case .locked: "workspace-write"
      case .guarded: "workspace-write"
      case .autonomous: "workspace-write"
      case .open: "danger-full-access"
      case .fullAuto: "workspace-write"
      case .unrestricted: "danger-full-access"
    }
  }

  /// Infer autonomy level from approval policy + sandbox mode strings
  static func from(approvalPolicy: String?, sandboxMode: String?) -> AutonomyLevel {
    switch (approvalPolicy, sandboxMode) {
      case ("untrusted", _):
        .locked
      case ("on-failure", _):
        .guarded
      case ("on-request", "danger-full-access"):
        .open
      case ("on-request", _):
        .autonomous
      case ("never", "danger-full-access"):
        .unrestricted
      case ("never", _):
        .fullAuto
      case (nil, nil):
        .autonomous
      default:
        .autonomous
    }
  }

  /// Index in CaseIterable for track positioning
  var index: Int {
    Self.allCases.firstIndex(of: self) ?? 0
  }
}

// MARK: - Compact Autonomy Pill

struct AutonomyPill: View {
  enum PillSize {
    case regular
    case statusBar

    var iconFontSize: CGFloat {
      switch self {
        case .regular: TypeScale.body
        case .statusBar: IconScale.sm
      }
    }

    var textFontSize: CGFloat {
      switch self {
        case .regular: TypeScale.body
        case .statusBar: TypeScale.micro
      }
    }

    var horizontalPadding: CGFloat {
      switch self {
        case .regular: CGFloat(Spacing.md)
        case .statusBar: CGFloat(Spacing.sm)
      }
    }

    var verticalPadding: CGFloat {
      switch self {
        case .regular: CGFloat(Spacing.sm)
        case .statusBar: CGFloat(Spacing.xs)
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
        case .statusBar:
          #if os(iOS)
            30
          #else
            20
          #endif
      }
    }
  }

  let currentLevel: AutonomyLevel
  let isConfiguredOnServer: Bool
  var size: PillSize = .regular
  var isActive: Bool = false
  var onTapOverride: (() -> Void)?
  var onUpdate: ((AutonomyLevel) -> Void)?
  var onApplyCurrentSelection: (() -> Void)?
  @State private var showPopover = false

  var body: some View {
    Button {
      if let onTapOverride {
        onTapOverride()
      } else {
        showPopover.toggle()
      }
    } label: {
      HStack(spacing: size.spacing) {
        Image(systemName: currentLevel.icon)
          .font(.system(size: size.iconFontSize, weight: .semibold))
        Text(currentLevel.displayName)
          .font(.system(size: size.textFontSize, weight: .semibold))
        if !isConfiguredOnServer {
          Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: TypeScale.caption, weight: .semibold))
        }
      }
      .foregroundStyle(isActive ? Color.backgroundSecondary : currentLevel.color)
      .padding(.horizontal, size.horizontalPadding)
      .padding(.vertical, size.verticalPadding)
      .frame(height: size.height)
      .background(
        isActive
          ? AnyShapeStyle(currentLevel.color)
          : AnyShapeStyle(currentLevel.color.opacity(OpacityTier.light)),
        in: Capsule()
      )
      .overlay(
        Capsule()
          .strokeBorder(currentLevel.color.opacity(OpacityTier.medium), lineWidth: 0.75)
      )
      .themeShadow(Shadow.sm)
    }
    .buttonStyle(.plain)
    .fixedSize()
    .animation(Motion.snappy, value: isActive)
    .platformPopover(isPresented: $showPopover) {
      AutonomyPopover(selection: Binding(
        get: { currentLevel },
        set: { newLevel in onUpdate?(newLevel) }
      ), isConfiguredOnServer: isConfiguredOnServer, onApplyCurrentSelection: onApplyCurrentSelection)
    }
  }
}

// MARK: - Rich Autonomy Popover

struct AutonomyPopover: View {
  @Binding var selection: AutonomyLevel
  let isConfiguredOnServer: Bool
  let onApplyCurrentSelection: (() -> Void)?
  @State private var selectedIndex: Int = 0
  @Environment(\.dismiss) private var dismiss

  private let levels = AutonomyLevel.allCases

  init(
    selection: Binding<AutonomyLevel>,
    isConfiguredOnServer: Bool = true,
    onApplyCurrentSelection: (() -> Void)? = nil
  ) {
    _selection = selection
    self.isConfiguredOnServer = isConfiguredOnServer
    self.onApplyCurrentSelection = onApplyCurrentSelection
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        // Header — macOS only (iOS uses .navigationTitle)
        #if !os(iOS)
          Text("Autonomy Level")
            .font(.system(size: TypeScale.subhead, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.sm)
        #endif

        // Risk spectrum track
        AutonomyTrack(selection: $selection)
          .padding(.horizontal, Spacing.lg)
          .padding(.top, Spacing.sm)
          .padding(.bottom, Spacing.md)

        if !isConfiguredOnServer {
          HStack(alignment: .center, spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(Color.autonomyOpen)

            Text("Autonomy is not configured on the server for this session.")
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.textSecondary)

            Spacer(minLength: Spacing.sm)

            if let onApplyCurrentSelection {
              Button("Apply \(selection.displayName)") {
                onApplyCurrentSelection()
              }
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .buttonStyle(.borderedProminent)
              .controlSize(.mini)
            }
          }
          .padding(.horizontal, Spacing.lg)
          .padding(.bottom, Spacing.sm)
        }

        Divider()
          .background(Color.surfaceBorder)

        // Level rows
        VStack(spacing: 0) {
          ForEach(Array(levels.enumerated()), id: \.element.id) { idx, level in
            AutonomyLevelRow(
              level: level,
              isSelected: level == selection,
              isHighlighted: idx == selectedIndex
            )
            .contentShape(Rectangle())
            .onTapGesture {
              selection = level
              selectedIndex = idx
            }
            .platformHover { hovering in
              if hovering { selectedIndex = idx }
            }
          }
        }
        .padding(.vertical, Spacing.xs)
      }
    }
    .scrollBounceBehavior(.basedOnSize)
    #if os(iOS)
      .frame(maxWidth: .infinity)
      .navigationTitle("Autonomy Level")
      .navigationBarTitleDisplayMode(.inline)
    #endif
      .ifMacOS { $0.frame(width: 340) }
      .background(Color.backgroundSecondary)
      .onAppear {
        selectedIndex = selection.index
      }
      .ifMacOS { view in
        view
          .onKeyPress(.upArrow) {
            selectedIndex = max(0, selectedIndex - 1)
            return .handled
          }
          .onKeyPress(.downArrow) {
            selectedIndex = min(levels.count - 1, selectedIndex + 1)
            return .handled
          }
          .onKeyPress(.return) {
            selection = levels[selectedIndex]
            dismiss()
            return .handled
          }
          .onKeyPress(.escape) {
            dismiss()
            return .handled
          }
      }
  }
}

// MARK: - Risk Spectrum Track

struct AutonomyTrack: View {
  @Binding var selection: AutonomyLevel

  private let levels = AutonomyLevel.allCases

  var body: some View {
    VStack(spacing: Spacing.xs) {
      // Segmented track — tap to select
      GeometryReader { geo in
        let segmentWidth = geo.size.width / CGFloat(levels.count)

        ZStack {
          // Segmented color track
          HStack(spacing: Spacing.xxs) {
            ForEach(levels, id: \.id) { level in
              Capsule()
                .fill(level.color.opacity(level == selection ? OpacityTier.strong : OpacityTier.medium))
                .frame(maxWidth: .infinity)
            }
          }
          .frame(height: 4)

          // Level dots (tap targets)
          ForEach(Array(levels.enumerated()), id: \.element.id) { idx, level in
            let x = segmentWidth * (CGFloat(idx) + 0.5)
            let isActive = level == selection

            Circle()
              .fill(isActive ? level.color : Color.backgroundSecondary)
              .frame(width: isActive ? 10 : 6, height: isActive ? 10 : 6)
              .overlay(
                Circle()
                  .stroke(level.color, lineWidth: isActive ? 0 : 1.5)
              )
              .themeShadow(Shadow.glow(color: isActive ? level.color : .clear, intensity: 0.6))
              .position(x: x, y: 6)
              .contentShape(Rectangle().size(width: segmentWidth, height: 20))
              .onTapGesture {
                selection = level
              }
          }
        }
        .frame(height: 12)
      }
      .frame(height: 12)

      // End labels
      HStack {
        Text("Restrictive")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.autonomyLocked)
        Spacer()
        Text("Permissive")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.autonomyUnrestricted)
      }
    }
  }
}

// MARK: - Level Row

struct AutonomyLevelRow: View {
  let level: AutonomyLevel
  let isSelected: Bool
  let isHighlighted: Bool

  var body: some View {
    HStack(spacing: 0) {
      // Color edge bar
      RoundedRectangle(cornerRadius: 1.5)
        .fill(level.color)
        .frame(width: EdgeBar.width)
        .padding(.vertical, Spacing.sm)

      VStack(alignment: .leading, spacing: Spacing.xs) {
        // Top line: icon + name + badges
        HStack(spacing: Spacing.sm) {
          Image(systemName: level.icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(level.color)
            .frame(width: 20)

          Text(level.displayName)
            .font(.system(size: TypeScale.subhead, weight: .semibold))
            .foregroundStyle(isSelected ? level.color : Color.textPrimary)

          if level.isDefault {
            Text("DEFAULT")
              .font(.system(size: 8, weight: .bold, design: .rounded))
              .foregroundStyle(Color.autonomyAutonomous)
              .padding(.horizontal, 5)
              .padding(.vertical, Spacing.xxs)
              .background(Color.autonomyAutonomous.opacity(OpacityTier.light), in: Capsule())
          }

          Spacer()

          if isSelected {
            Image(systemName: "checkmark")
              .font(.system(size: 10, weight: .bold))
              .foregroundStyle(level.color)
          }
        }

        // Bottom line: description
        Text(level.description)
          .font(.system(size: TypeScale.body, weight: .regular))
          .foregroundStyle(Color.textSecondary)
          .padding(.leading, Spacing.xxl) // align with text after icon

        // Metadata line: approval + sandbox
        HStack(spacing: Spacing.md) {
          // Approval behavior
          HStack(spacing: Spacing.xs) {
            Image(systemName: level.approvalBehavior.contains("Never") ? "hand.raised.slash" : "hand.raised.fill")
              .font(.system(size: 9))
            Text(level.approvalBehavior)
              .font(.system(size: TypeScale.caption, weight: .medium))
          }
          .foregroundStyle(Color.textTertiary)

          // Sandbox indicator
          HStack(spacing: Spacing.xxs) {
            Image(systemName: level.isSandboxed ? "shield.fill" : "shield.slash")
              .font(.system(size: 9))
            Text(level.isSandboxed ? "Sandboxed" : "No sandbox")
              .font(.system(size: TypeScale.caption, weight: .medium))
          }
          .foregroundStyle(level.isSandboxed ? Color.textTertiary : Color.autonomyOpen.opacity(0.8))
        }
        .padding(.leading, Spacing.xxl) // align with text after icon
      }
      .padding(.leading, Spacing.sm)
      .padding(.trailing, Spacing.lg)
      .padding(.vertical, Spacing.md)
    }
    .background(
      isHighlighted
        ? level.color.opacity(OpacityTier.tint)
        : Color.clear
    )
    .animation(Motion.hover, value: isHighlighted)
  }
}

// MARK: - Inline Autonomy Picker (for session creation sheet)

struct InlineAutonomyPicker: View {
  @Binding var selection: AutonomyLevel

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      AutonomyPopover(selection: $selection)
        .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.lg)
            .stroke(Color.surfaceBorder, lineWidth: 1)
        )
    }
  }
}

#Preview("Autonomy Pill") {
  HStack {
    AutonomyPill(currentLevel: .autonomous, isConfiguredOnServer: true)
  }
  .padding()
  .background(Color.backgroundPrimary)
}

#Preview("Autonomy Popover") {
  AutonomyPopover(selection: .constant(.autonomous))
    .background(Color.backgroundSecondary)
}

#Preview("Inline Picker") {
  InlineAutonomyPicker(selection: .constant(.autonomous))
    .padding()
    .background(Color.backgroundPrimary)
}
