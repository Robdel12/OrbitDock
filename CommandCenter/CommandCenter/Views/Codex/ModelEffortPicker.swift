//
//  ModelEffortPicker.swift
//  OrbitDock
//
//  Popover for model and effort selection.
//  Models: two-line rows (name + description).
//  Efforts: single-line rows with colored dots + track.
//

import SwiftUI

// MARK: - Model & Effort Popover

struct ModelEffortPopover: View {
  @Binding var selectedModel: String
  @Binding var selectedEffort: EffortLevel
  let models: [ServerCodexModelOption]
  @Environment(\.dismiss) private var dismiss

  @State private var hoveredEffort: EffortLevel?

  private var filteredModels: [ServerCodexModelOption] {
    models.filter { !$0.model.isEmpty }
  }

  private var selectedModelOption: ServerCodexModelOption? {
    filteredModels.first { $0.model == selectedModel }
  }

  private var supportedEfforts: Set<String> {
    Set(selectedModelOption?.supportedReasoningEfforts ?? [])
  }

  /// Only show efforts that are supported by the current model (plus .default always)
  private var visibleEffortLevels: [EffortLevel] {
    EffortLevel.allCases.filter { level in
      level == .default
        || supportedEfforts.isEmpty
        || supportedEfforts.contains(level.rawValue)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // ━━━ Models ━━━
      sectionHeader("Model")

      ForEach(filteredModels, id: \.id) { model in
        ModelRow(
          model: model,
          isSelected: model.model == selectedModel
        )
        .contentShape(Rectangle())
        .onTapGesture { selectModel(model) }
      }

      divider

      // ━━━ Effort ━━━
      HStack {
        sectionHeader("Reasoning Effort")
        Spacer()
        if selectedEffort != .default {
          Button("Reset") {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
              selectedEffort = .default
            }
          }
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(Color.accent)
          .buttonStyle(.plain)
          .padding(.trailing, Spacing.lg)
          .padding(.top, Spacing.sm)
        }
      }

      // Track
      EffortTrack(
        selection: $selectedEffort,
        supportedEfforts: supportedEfforts
      )
      .padding(.horizontal, Spacing.lg)
      .padding(.bottom, Spacing.sm)

      // Effort rows (only show supported levels + default)
      ForEach(visibleEffortLevels, id: \.self) { level in
        EffortRow(
          level: level,
          isSelected: level == selectedEffort,
          isHovered: hoveredEffort == level
        )
        .contentShape(Rectangle())
        .onTapGesture {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            selectedEffort = level
          }
        }
        .onHover { hovering in
          hoveredEffort = hovering ? level : nil
        }
      }

      // Bottom padding
      Spacer().frame(height: Spacing.xs)
    }
    .frame(width: 320)
    .background(Color.backgroundSecondary)
    .onKeyPress(.escape) {
      dismiss()
      return .handled
    }
  }

  // MARK: - Helpers

  private func sectionHeader(_ title: String) -> some View {
    Text(title.uppercased())
      .font(.system(size: 9, weight: .bold, design: .monospaced))
      .foregroundStyle(Color.textTertiary)
      .tracking(1.2)
      .padding(.horizontal, Spacing.lg)
      .padding(.top, Spacing.md)
      .padding(.bottom, Spacing.xs)
  }

  private var divider: some View {
    Rectangle()
      .fill(Color.surfaceBorder)
      .frame(height: 1)
      .padding(.top, Spacing.xs)
  }

  private func selectModel(_ model: ServerCodexModelOption) {
    selectedModel = model.model
    let newSupported = Set(model.supportedReasoningEfforts)
    if selectedEffort != .default,
       !newSupported.isEmpty,
       !newSupported.contains(selectedEffort.rawValue)
    {
      withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
        selectedEffort = .default
      }
    }
  }
}

// MARK: - Model Row

private struct ModelRow: View {
  let model: ServerCodexModelOption
  let isSelected: Bool
  @State private var isHovered = false

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: Spacing.sm) {
          Text(model.displayName)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(isSelected ? Color.providerCodex : Color.textPrimary)

          if model.isDefault {
            Text("DEFAULT")
              .font(.system(size: 7, weight: .bold, design: .rounded))
              .foregroundStyle(Color.providerCodex)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(Color.providerCodex.opacity(OpacityTier.light), in: Capsule())
          }
        }

        if !model.description.isEmpty {
          Text(model.description)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
        }
      }

      Spacer()

      if isSelected {
        Image(systemName: "checkmark")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(Color.providerCodex)
          .padding(.top, 2)
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
    .background(isHovered ? Color.surfaceHover : Color.clear)
    .onHover { isHovered = $0 }
  }
}

// MARK: - Effort Track

private struct EffortTrack: View {
  @Binding var selection: EffortLevel
  let supportedEfforts: Set<String>

  private let levels = EffortLevel.concreteCases

  var body: some View {
    VStack(spacing: Spacing.xxs) {
      GeometryReader { geo in
        let segmentWidth = geo.size.width / CGFloat(levels.count)

        ZStack {
          // Background bar
          Capsule()
            .fill(Color.backgroundTertiary)
            .frame(height: 3)

          // Gradient fill up to selection
          if let selIdx = levels.firstIndex(of: selection) {
            let fillWidth = segmentWidth * (CGFloat(selIdx) + 0.5)
            Capsule()
              .fill(
                LinearGradient(
                  colors: Array(levels.prefix(selIdx + 1).map(\.color)),
                  startPoint: .leading,
                  endPoint: .trailing
                )
              )
              .frame(width: fillWidth, height: 3)
              .frame(maxWidth: .infinity, alignment: .leading)
          }

          // Dots
          ForEach(Array(levels.enumerated()), id: \.element.id) { idx, level in
            let x = segmentWidth * (CGFloat(idx) + 0.5)
            let isActive = level == selection
            let isSupported = supportedEfforts.isEmpty || supportedEfforts.contains(level.rawValue)

            Circle()
              .fill(isActive ? level.color : Color.backgroundSecondary)
              .frame(width: isActive ? 10 : 6, height: isActive ? 10 : 6)
              .overlay(
                Circle().stroke(level.color.opacity(isSupported ? 0.8 : 0.2), lineWidth: isActive ? 0 : 1.5)
              )
              .shadow(color: isActive ? level.color.opacity(0.5) : .clear, radius: 4)
              .opacity(isSupported ? 1 : 0.35)
              .position(x: x, y: 6)
              .contentShape(Rectangle().size(width: segmentWidth, height: 16))
              .onTapGesture {
                guard isSupported else { return }
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                  selection = level
                }
              }
              .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isActive)
          }
        }
        .frame(height: 12)
      }
      .frame(height: 12)

      HStack {
        Text("Fastest")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.effortNone)
        Spacer()
        Text("Deepest")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.effortXHigh)
      }
    }
  }
}

// MARK: - Effort Row

private struct EffortRow: View {
  let level: EffortLevel
  let isSelected: Bool
  let isHovered: Bool

  var body: some View {
    let color: Color = level == .default ? .textSecondary : level.color

    HStack(alignment: .top, spacing: Spacing.sm) {
      // Color dot (vertically centered with name)
      if level != .default {
        Circle()
          .fill(color)
          .frame(width: 6, height: 6)
          .padding(.top, 5)
      }

      VStack(alignment: .leading, spacing: 2) {
        // Name + badges + speed label
        HStack(spacing: Spacing.sm) {
          Text(level.displayName)
            .font(.system(size: TypeScale.body, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? color : Color.textPrimary)

          if level.isDefault {
            Text("DEFAULT")
              .font(.system(size: 7, weight: .bold, design: .rounded))
              .foregroundStyle(Color.effortMedium)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(Color.effortMedium.opacity(OpacityTier.light), in: Capsule())
          }

          Spacer()

          if !level.speedLabel.isEmpty {
            Text(level.speedLabel)
              .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
          }

          if isSelected {
            Image(systemName: "checkmark")
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(color)
          }
        }

        // Description on its own line
        Text(level.description)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
    .background(isHovered ? Color.surfaceHover : Color.clear)
  }
}

// MARK: - Previews

#Preview("Model & Effort Popover") {
  ModelEffortPopover(
    selectedModel: .constant("gpt-5.3-codex"),
    selectedEffort: .constant(.default),
    models: [
      ServerCodexModelOption(
        id: "1", model: "gpt-5.3-codex",
        displayName: "GPT-5.3 Codex",
        description: "Latest frontier agentic model",
        isDefault: true,
        supportedReasoningEfforts: ["low", "medium", "high", "xhigh"]
      ),
      ServerCodexModelOption(
        id: "2", model: "gpt-5.2-codex",
        displayName: "GPT-5.2 Codex",
        description: "Frontier agentic coding model",
        isDefault: false,
        supportedReasoningEfforts: ["low", "medium", "high", "xhigh"]
      ),
      ServerCodexModelOption(
        id: "3", model: "gpt-5.1-codex-mini",
        displayName: "GPT-5.1 Codex Mini",
        description: "Optimized for codex. Cheaper, faster, but less capable",
        isDefault: false,
        supportedReasoningEfforts: ["medium", "high"]
      ),
    ]
  )
}
