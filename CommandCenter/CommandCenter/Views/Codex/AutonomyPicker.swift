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

  var id: String { rawValue }

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

  var isDefault: Bool { self == .autonomous }

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
  let sessionId: String
  @Environment(ServerAppState.self) private var serverState
  @State private var showPopover = false

  private var currentLevel: AutonomyLevel {
    serverState.session(sessionId).autonomy
  }

  var body: some View {
    Button {
      showPopover.toggle()
    } label: {
      HStack(spacing: Spacing.xs) {
        Image(systemName: currentLevel.icon)
          .font(.system(size: TypeScale.body, weight: .semibold))
        Text(currentLevel.displayName)
          .font(.system(size: TypeScale.body, weight: .semibold))
      }
      .foregroundStyle(currentLevel.color)
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .background(currentLevel.color.opacity(OpacityTier.light), in: Capsule())
    }
    .buttonStyle(.plain)
    .fixedSize()
    .popover(isPresented: $showPopover, arrowEdge: .bottom) {
      AutonomyPopover(selection: Binding(
        get: { currentLevel },
        set: { newLevel in
          serverState.updateSessionConfig(sessionId: sessionId, autonomy: newLevel)
        }
      ))
    }
  }
}

// MARK: - Rich Autonomy Popover

struct AutonomyPopover: View {
  @Binding var selection: AutonomyLevel
  @State private var selectedIndex: Int = 0
  @Environment(\.dismiss) private var dismiss

  private let levels = AutonomyLevel.allCases

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header
      Text("Autonomy Level")
        .font(.system(size: TypeScale.subhead, weight: .semibold))
        .foregroundStyle(Color.textPrimary)
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.lg)
        .padding(.bottom, Spacing.sm)

      // Risk spectrum track
      AutonomyTrack(selection: $selection)
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.md)

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
          .onHover { hovering in
            if hovering { selectedIndex = idx }
          }
        }
      }
      .padding(.vertical, Spacing.xs)
    }
    .frame(width: 340)
    .background(Color.backgroundSecondary)
    .onAppear {
      selectedIndex = selection.index
    }
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
          // Gradient bar
          Capsule()
            .fill(
              LinearGradient(
                colors: levels.map(\.color),
                startPoint: .leading,
                endPoint: .trailing
              )
            )
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
              .shadow(color: isActive ? level.color.opacity(0.6) : .clear, radius: 4)
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
              .padding(.vertical, 2)
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
          .padding(.leading, 32) // align with text after icon

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
        .padding(.leading, 32) // align with text after icon
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
    .animation(.easeOut(duration: 0.1), value: isHighlighted)
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
    AutonomyPill(sessionId: "test")
  }
  .padding()
  .background(Color.backgroundPrimary)
  .environment(ServerAppState())
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
