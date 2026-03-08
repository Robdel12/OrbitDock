//
//  ClaudePermissionPicker.swift
//  OrbitDock
//
//  Permission mode enum and compact picker for Claude direct sessions.
//  Follows the AutonomyPicker pattern — pill + popover + inline variant.
//

import SwiftUI

// MARK: - Claude Permission Mode

enum ClaudePermissionMode: String, CaseIterable, Identifiable {
  case plan
  case dontAsk
  case `default`
  case acceptEdits
  case bypassPermissions

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
      case .plan: "Plan Mode"
      case .dontAsk: "Don't Ask"
      case .default: "Default"
      case .acceptEdits: "Accept Edits"
      case .bypassPermissions: "Bypass Permissions"
    }
  }

  var icon: String {
    switch self {
      case .plan: "map.fill"
      case .dontAsk: "hand.raised.fill"
      case .default: "shield.lefthalf.filled"
      case .acceptEdits: "pencil.and.outline"
      case .bypassPermissions: "bolt.fill"
    }
  }

  var description: String {
    switch self {
      case .plan: "Read-only — plan but don't execute"
      case .dontAsk: "Deny tools not pre-approved — no prompts"
      case .default: "Ask permission for file writes and commands"
      case .acceptEdits: "Auto-approve file edits, ask for commands"
      case .bypassPermissions: "Auto-approve everything"
    }
  }

  var color: Color {
    switch self {
      case .plan: .statusQuestion
      case .dontAsk: .feedbackCaution
      case .default: .autonomyGuarded
      case .acceptEdits: .autonomyAutonomous
      case .bypassPermissions: .autonomyUnrestricted
    }
  }

  var isDefault: Bool {
    self == .default
  }

  /// Index in CaseIterable for track positioning
  var index: Int {
    Self.allCases.firstIndex(of: self) ?? 0
  }
}

// MARK: - Compact Permission Pill

struct ClaudePermissionPill: View {
  enum PillSize {
    case regular
    case statusBar

    var iconFontSize: CGFloat {
      switch self {
        case .regular: TypeScale.body
        case .statusBar: 9
      }
    }

    var textFontSize: CGFloat {
      switch self {
        case .regular: TypeScale.body
        case .statusBar: 10
      }
    }

    var horizontalPadding: CGFloat {
      switch self {
        case .regular: CGFloat(Spacing.md)
        case .statusBar: 6
      }
    }

    var verticalPadding: CGFloat {
      switch self {
        case .regular: CGFloat(Spacing.sm)
        case .statusBar: 3
      }
    }

    var spacing: CGFloat {
      switch self {
        case .regular: CGFloat(Spacing.xs)
        case .statusBar: 3
      }
    }

    var height: CGFloat? {
      switch self {
        case .regular: nil
        case .statusBar: 20
      }
    }
  }

  let sessionId: String
  var size: PillSize = .regular
  var isActive: Bool = false
  var onTapOverride: (() -> Void)?
  @Environment(ServerAppState.self) private var serverState
  @State private var showPopover = false

  private var currentMode: ClaudePermissionMode {
    serverState.session(sessionId).permissionMode
  }

  var body: some View {
    Button {
      if let onTapOverride {
        onTapOverride()
      } else {
        showPopover.toggle()
      }
    } label: {
      HStack(spacing: size.spacing) {
        Image(systemName: currentMode.icon)
          .font(.system(size: size.iconFontSize, weight: .semibold))
        Text(currentMode.displayName)
          .font(.system(size: size.textFontSize, weight: .semibold))
      }
      .foregroundStyle(isActive ? Color.backgroundSecondary : currentMode.color)
      .padding(.horizontal, size.horizontalPadding)
      .padding(.vertical, size.verticalPadding)
      .frame(height: size.height)
      .background(
        isActive
          ? AnyShapeStyle(currentMode.color)
          : AnyShapeStyle(currentMode.color.opacity(OpacityTier.light)),
        in: Capsule()
      )
    }
    .buttonStyle(.plain)
    .fixedSize()
    .animation(Motion.snappy, value: isActive)
    .platformPopover(isPresented: $showPopover) {
      ClaudePermissionPopover(selection: Binding(
        get: { currentMode },
        set: { newMode in
          serverState.updateClaudePermissionMode(sessionId: sessionId, mode: newMode)
        }
      ))
    }
  }
}

// MARK: - Rich Permission Popover

struct ClaudePermissionPopover: View {
  @Binding var selection: ClaudePermissionMode
  @State private var selectedIndex: Int = 0
  @Environment(\.dismiss) private var dismiss

  private let modes = ClaudePermissionMode.allCases

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header
      Text("Permission Mode")
        .font(.system(size: TypeScale.subhead, weight: .semibold))
        .foregroundStyle(Color.textPrimary)
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.lg)
        .padding(.bottom, Spacing.sm)

      // Risk spectrum track
      ClaudePermissionTrack(selection: $selection)
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.md)

      Divider()
        .background(Color.surfaceBorder)

      // Mode rows
      VStack(spacing: 0) {
        ForEach(Array(modes.enumerated()), id: \.element.id) { idx, mode in
          ClaudePermissionRow(
            mode: mode,
            isSelected: mode == selection,
            isHighlighted: idx == selectedIndex
          )
          .contentShape(Rectangle())
          .onTapGesture {
            selection = mode
            selectedIndex = idx
          }
          .platformHover { hovering in
            if hovering { selectedIndex = idx }
          }
        }
      }
      .padding(.vertical, Spacing.xs)
    }
    #if os(iOS)
    .frame(maxWidth: .infinity)
    .navigationTitle("Permission Mode")
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
          selectedIndex = min(modes.count - 1, selectedIndex + 1)
          return .handled
        }
        .onKeyPress(.return) {
          selection = modes[selectedIndex]
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

// MARK: - Permission Spectrum Track

struct ClaudePermissionTrack: View {
  @Binding var selection: ClaudePermissionMode

  private let modes = ClaudePermissionMode.allCases

  var body: some View {
    VStack(spacing: Spacing.xs) {
      // Segmented track — tap to select
      GeometryReader { geo in
        let segmentWidth = geo.size.width / CGFloat(modes.count)

        ZStack {
          // Segmented color track
          HStack(spacing: Spacing.xxs) {
            ForEach(modes, id: \.id) { mode in
              Capsule()
                .fill(mode.color.opacity(mode == selection ? OpacityTier.strong : OpacityTier.medium))
                .frame(maxWidth: .infinity)
            }
          }
          .frame(height: 4)

          // Mode dots (tap targets)
          ForEach(Array(modes.enumerated()), id: \.element.id) { idx, mode in
            let x = segmentWidth * (CGFloat(idx) + 0.5)
            let isActive = mode == selection

            Circle()
              .fill(isActive ? mode.color : Color.backgroundSecondary)
              .frame(width: isActive ? 10 : 6, height: isActive ? 10 : 6)
              .overlay(
                Circle()
                  .stroke(mode.color, lineWidth: isActive ? 0 : 1.5)
              )
              .themeShadow(Shadow.glow(color: isActive ? mode.color : .clear, intensity: 0.6))
              .position(x: x, y: 6)
              .contentShape(Rectangle().size(width: segmentWidth, height: 20))
              .onTapGesture {
                selection = mode
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
          .foregroundStyle(ClaudePermissionMode.default.color)
        Spacer()
        Text("Permissive")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(ClaudePermissionMode.bypassPermissions.color)
      }
    }
  }
}

// MARK: - Permission Row

struct ClaudePermissionRow: View {
  let mode: ClaudePermissionMode
  let isSelected: Bool
  let isHighlighted: Bool

  var body: some View {
    HStack(spacing: 0) {
      // Color edge bar
      RoundedRectangle(cornerRadius: 1.5)
        .fill(mode.color)
        .frame(width: EdgeBar.width)
        .padding(.vertical, Spacing.sm)

      VStack(alignment: .leading, spacing: Spacing.xs) {
        // Top line: icon + name + badges
        HStack(spacing: Spacing.sm) {
          Image(systemName: mode.icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(mode.color)
            .frame(width: 20)

          Text(mode.displayName)
            .font(.system(size: TypeScale.subhead, weight: .semibold))
            .foregroundStyle(isSelected ? mode.color : Color.textPrimary)

          if mode.isDefault {
            Text("DEFAULT")
              .font(.system(size: 8, weight: .bold, design: .rounded))
              .foregroundStyle(ClaudePermissionMode.default.color)
              .padding(.horizontal, 5)
              .padding(.vertical, Spacing.xxs)
              .background(ClaudePermissionMode.default.color.opacity(OpacityTier.light), in: Capsule())
          }

          Spacer()

          if isSelected {
            Image(systemName: "checkmark")
              .font(.system(size: 10, weight: .bold))
              .foregroundStyle(mode.color)
          }
        }

        // Bottom line: description
        Text(mode.description)
          .font(.system(size: TypeScale.body, weight: .regular))
          .foregroundStyle(Color.textSecondary)
          .padding(.leading, Spacing.xxl)
      }
      .padding(.leading, Spacing.sm)
      .padding(.trailing, Spacing.lg)
      .padding(.vertical, Spacing.md)
    }
    .background(
      isHighlighted
        ? mode.color.opacity(OpacityTier.tint)
        : Color.clear
    )
    .animation(Motion.hover, value: isHighlighted)
  }
}

// MARK: - Inline Permission Picker (for session creation sheet)

struct InlineClaudePermissionPicker: View {
  @Binding var selection: ClaudePermissionMode

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      ClaudePermissionPopover(selection: $selection)
        .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.lg)
            .stroke(Color.surfaceBorder, lineWidth: 1)
        )
    }
  }
}

#Preview("Permission Pill") {
  HStack {
    ClaudePermissionPill(sessionId: "test")
  }
  .padding()
  .background(Color.backgroundPrimary)
  .environment(ServerAppState())
}

#Preview("Permission Popover") {
  ClaudePermissionPopover(selection: .constant(.default))
    .background(Color.backgroundSecondary)
}

#Preview("Inline Picker") {
  InlineClaudePermissionPicker(selection: .constant(.default))
    .padding()
    .background(Color.backgroundPrimary)
}
