//
//  ModelEffortPicker.swift
//  OrbitDock
//
//  Compact popover for model and effort selection inside chat.
//  Keeps metadata visible without turning into a full settings UI.
//

import SwiftUI

// MARK: - Model & Effort Popover

struct ModelEffortPopover: View {
  @Binding var selectedModel: String
  @Binding var selectedEffort: EffortLevel
  let models: [ServerCodexModelOption]

  @Environment(\.dismiss) private var dismiss
  @State private var showModelPicker = false
  @State private var searchQuery = ""

  private var availableModels: [ServerCodexModelOption] {
    models
      .filter { !$0.model.isEmpty }
      .sorted(by: compareModels)
  }

  private var selectedModelOption: ServerCodexModelOption? {
    availableModels.first { $0.model == selectedModel }
  }

  private var selectedProviderTitle: String {
    guard let selectedModelOption else { return "Unknown" }
    return providerKey(for: selectedModelOption).title
  }

  private var supportedEfforts: Set<String> {
    Set(selectedModelOption?.supportedReasoningEfforts ?? [])
  }

  private var visibleEffortLevels: [EffortLevel] {
    EffortLevel.allCases.filter { level in
      level == .default
        || supportedEfforts.isEmpty
        || supportedEfforts.contains(level.rawValue)
    }
  }

  private var trimmedQuery: String {
    searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private var showSearch: Bool {
    availableModels.count > 12 || !trimmedQuery.isEmpty
  }

  private var filteredModels: [ServerCodexModelOption] {
    guard !trimmedQuery.isEmpty else { return availableModels }

    return availableModels.filter { model in
      let provider = providerKey(for: model).title
      let haystack = "\(model.displayName) \(model.model) \(model.description) \(provider)"
      return haystack.lowercased().contains(trimmedQuery)
    }
  }

  private var groupedModels: [ModelGroup] {
    let grouped = Dictionary(grouping: filteredModels, by: providerKey(for:))

    return grouped
      .map { key, value in
        ModelGroup(
          id: key.id,
          title: key.title,
          tint: providerTint(for: key.id),
          models: value.sorted(by: compareModels)
        )
      }
      .sorted(by: compareModelGroups)
  }

  private var modelListHeight: CGFloat {
    let rowHeight: CGFloat = 44
    let groupHeaderHeight: CGFloat = 16
    let rowCount = CGFloat(filteredModels.count)
    let headerCount = groupedModels.count > 1 ? CGFloat(groupedModels.count) : 0
    let estimated = (rowCount * rowHeight) + (headerCount * groupHeaderHeight) + 8
    let minHeight: CGFloat = showModelPicker ? 120 : 96
    let maxHeight: CGFloat = showModelPicker ? 248 : 188
    return min(max(estimated, minHeight), maxHeight)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header

      modelSection

      divider

      effortSection
    }
    .frame(width: 356)
    .background(Color.backgroundSecondary)
    .animation(.spring(response: 0.25, dampingFraction: 0.84), value: showModelPicker)
    .onKeyPress(.escape) {
      dismiss()
      return .handled
    }
  }

  // MARK: - Sections

  private var header: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Model + Effort")
        .font(.system(size: TypeScale.title, weight: .semibold))
        .foregroundStyle(Color.textPrimary)
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.top, Spacing.md)
    .padding(.bottom, Spacing.md)
  }

  private var modelSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm) {
        Text("MODEL")
          .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
          .tracking(1.0)

        Spacer()

        Text(selectedProviderTitle.uppercased())
          .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
          .tracking(0.8)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(Color.backgroundTertiary, in: Capsule())
      }

      Button {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
          showModelPicker.toggle()
          if !showModelPicker { searchQuery = "" }
        }
      } label: {
        HStack(alignment: .center, spacing: Spacing.sm) {
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Spacing.sm) {
              Text(selectedModelOption?.displayName ?? "No model selected")
                .font(.system(size: TypeScale.body, weight: .semibold))
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)

              if selectedModelOption?.isDefault == true {
                Text("DEFAULT")
                  .font(.system(size: 7, weight: .bold, design: .rounded))
                  .foregroundStyle(Color.providerCodex)
                  .padding(.horizontal, 4)
                  .padding(.vertical, 1)
                  .background(Color.providerCodex.opacity(OpacityTier.light), in: Capsule())
              }
            }

            if !showModelPicker, let description = selectedModelOption?.description, !description.isEmpty {
              Text(description)
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Color.textTertiary)
                .lineLimit(1)
            }
          }

          Spacer(minLength: 0)

          Image(systemName: showModelPicker ? "chevron.up" : "chevron.down")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(Color.backgroundPrimary.opacity(0.28))
        )
        .overlay(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(Color.surfaceBorder.opacity(0.45), lineWidth: 1)
        )
      }
      .buttonStyle(.plain)

      if showModelPicker {
        if showSearch {
          searchBar
        }

        modelList
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
    .layoutPriority(showModelPicker ? 1 : 0)
  }

  private var searchBar: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: TypeScale.body, weight: .semibold))
        .foregroundStyle(Color.textQuaternary)

      TextField("Search models", text: $searchQuery)
        .textFieldStyle(.plain)
        .font(.system(size: TypeScale.body, weight: .medium))

      if !searchQuery.isEmpty {
        Button {
          searchQuery = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.backgroundTertiary)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .strokeBorder(Color.surfaceBorder.opacity(0.65), lineWidth: 1)
    )
  }

  private var modelList: some View {
    Group {
      if filteredModels.count <= 3 {
        modelListContent
      } else {
        ScrollView {
          modelListContent
        }
        .scrollIndicators(.visible)
        .frame(minHeight: 96, maxHeight: modelListHeight)
      }
    }
  }

  private var modelListContent: some View {
    LazyVStack(alignment: .leading, spacing: Spacing.xs) {
      if groupedModels.isEmpty {
        Text("No models match \"\(searchQuery)\"")
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.textSecondary)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.md)
      } else {
        ForEach(groupedModels) { group in
          if groupedModels.count > 1 {
            Text(group.title.uppercased())
              .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
              .foregroundStyle(group.tint.opacity(0.85))
              .tracking(0.9)
              .padding(.horizontal, Spacing.xs)
              .padding(.top, Spacing.sm)
              .padding(.bottom, Spacing.xxs)
          }

          ForEach(group.models, id: \.id) { model in
            CompactModelRow(
              model: model,
              isSelected: model.model == selectedModel,
              accent: group.tint
            ) {
              selectModel(model)
            }
          }
        }
      }
    }
    .padding(.bottom, Spacing.sm)
  }

  private var effortSection: some View {
    VStack(alignment: .leading, spacing: showModelPicker ? Spacing.xs : Spacing.sm) {
      HStack {
        Text("REASONING EFFORT")
          .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
          .tracking(1.0)

        Spacer()

        if !showModelPicker, selectedEffort != .default {
          Button("Default") {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
              selectedEffort = .default
            }
          }
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(Color.accent)
          .buttonStyle(.plain)
        }
      }

      HStack(spacing: 6) {
        Text("Current:")
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textQuaternary)

        Text(selectedEffort.displayName)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(selectedEffort == .default ? Color.accent : selectedEffort.color)

        if !selectedEffort.speedLabel.isEmpty {
          Text("· \(selectedEffort.speedLabel)")
            .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }
      }

      if !showModelPicker {
        VStack(spacing: Spacing.xs) {
          ForEach(visibleEffortLevels, id: \.self) { level in
            EffortListRow(level: level, isSelected: level == selectedEffort)
              .onTapGesture {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                  selectedEffort = level
                }
              }
          }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
    .layoutPriority(showModelPicker ? 0 : 1)
  }

  // MARK: - Helpers

  private var divider: some View {
    Rectangle()
      .fill(Color.surfaceBorder)
      .frame(height: 1)
  }

  private func selectModel(_ model: ServerCodexModelOption) {
    selectedModel = model.model

    let newSupported = Set(model.supportedReasoningEfforts)
    if selectedEffort != .default,
       !newSupported.isEmpty,
       !newSupported.contains(selectedEffort.rawValue)
    {
      selectedEffort = .default
    }

    withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
      showModelPicker = false
    }
    searchQuery = ""
  }

  private func compareModels(_ lhs: ServerCodexModelOption, _ rhs: ServerCodexModelOption) -> Bool {
    if lhs.model == selectedModel { return true }
    if rhs.model == selectedModel { return false }
    if lhs.isDefault != rhs.isDefault { return lhs.isDefault && !rhs.isDefault }
    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
  }

  private func compareModelGroups(_ lhs: ModelGroup, _ rhs: ModelGroup) -> Bool {
    let left = providerSortOrder(for: lhs.id)
    let right = providerSortOrder(for: rhs.id)

    if left != right { return left < right }
    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
  }

  private func providerKey(for option: ServerCodexModelOption) -> ProviderKey {
    let modelName = option.model.lowercased()
    let combined = "\(option.model) \(option.displayName)".lowercased()

    if let slash = modelName.firstIndex(of: "/") {
      let prefix = String(modelName[..<slash])
      if let mapped = mappedProvider(for: prefix) {
        return mapped
      }

      return ProviderKey(
        id: prefix,
        title: prefix.replacingOccurrences(of: "-", with: " ").capitalized
      )
    }

    if combined.contains("claude") || combined.contains("anthropic") { return .anthropic }
    if combined.contains("gemini") || combined.contains("google") { return .google }
    if combined.contains("grok") || combined.contains("xai") { return .xai }
    if combined.contains("llama") || combined.contains("meta") { return .meta }

    if combined.contains("gpt") || combined.contains("openai")
      || combined.contains("codex")
      || modelName.hasPrefix("o1")
      || modelName.hasPrefix("o3")
      || modelName.hasPrefix("o4")
    {
      return .openai
    }

    return .other
  }

  private func mappedProvider(for raw: String) -> ProviderKey? {
    switch raw {
    case "openai": .openai
    case "anthropic": .anthropic
    case "google", "gemini": .google
    case "xai": .xai
    case "meta": .meta
    default: nil
    }
  }

  private func providerSortOrder(for providerID: String) -> Int {
    switch providerID {
    case "openai": 0
    case "anthropic": 1
    case "google": 2
    case "xai": 3
    case "meta": 4
    default: 99
    }
  }

  private func providerTint(for providerID: String) -> Color {
    switch providerID {
    case "openai": .providerCodex
    case "anthropic": .providerClaude
    case "google": .providerGemini
    case "xai": .statusReply
    case "meta": .toolTodo
    default: .accentMuted
    }
  }
}

// MARK: - Model Row

private struct CompactModelRow: View {
  let model: ServerCodexModelOption
  let isSelected: Bool
  let accent: Color
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: Spacing.sm) {
            Text(model.displayName)
              .font(.system(size: TypeScale.body, weight: .semibold))
              .foregroundStyle(isSelected ? accent : Color.textPrimary)
              .lineLimit(1)

            if model.isDefault {
              Text("DEFAULT")
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(accent.opacity(OpacityTier.light), in: Capsule())
            }

            Spacer(minLength: 0)

            if isSelected {
              Image(systemName: "checkmark")
                .font(.system(size: TypeScale.caption, weight: .bold))
                .foregroundStyle(accent)
            }
          }

          if isSelected, !model.description.isEmpty {
            Text(model.description)
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textTertiary)
              .lineLimit(1)
          }
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(isSelected ? accent.opacity(OpacityTier.light) : isHovered ? Color.surfaceHover : .clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .strokeBorder(
            isSelected ? accent.opacity(0.55) : Color.surfaceBorder.opacity(0.4),
            lineWidth: isSelected ? 1.2 : 1
          )
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
  }
}

// MARK: - Effort Chip

private struct EffortListRow: View {
  let level: EffortLevel
  let isSelected: Bool

  @State private var isHovered = false

  private var tint: Color {
    level == .default ? .accent : level.color
  }

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: Spacing.sm) {
          Text(level.displayName)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .lineLimit(1)

          Spacer(minLength: 0)

          if !level.speedLabel.isEmpty {
            Text(level.speedLabel)
              .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
          }

          if isSelected {
            Image(systemName: "checkmark")
              .font(.system(size: TypeScale.micro, weight: .bold))
          }
        }

        if isSelected {
          Text(level.description)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
        }
      }
    }
    .foregroundStyle(isSelected ? tint : Color.textSecondary)
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, isSelected ? Spacing.sm : 6)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(isSelected ? tint.opacity(OpacityTier.light) : isHovered ? Color.surfaceHover : .clear)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(
          isSelected ? tint.opacity(0.6) : Color.surfaceBorder.opacity(0.3),
          lineWidth: isSelected ? 1.2 : 1
        )
    )
    .onHover { isHovered = $0 }
  }
}

// MARK: - Value Types

private struct ModelGroup: Identifiable {
  let id: String
  let title: String
  let tint: Color
  let models: [ServerCodexModelOption]
}

private struct ProviderKey: Hashable {
  let id: String
  let title: String
}

private extension ProviderKey {
  static let openai = ProviderKey(id: "openai", title: "OpenAI")
  static let anthropic = ProviderKey(id: "anthropic", title: "Anthropic")
  static let google = ProviderKey(id: "google", title: "Google")
  static let xai = ProviderKey(id: "xai", title: "xAI")
  static let meta = ProviderKey(id: "meta", title: "Meta")
  static let other = ProviderKey(id: "other", title: "Other")
}

// MARK: - Previews

#Preview("Model & Effort Popover") {
  ModelEffortPopover(
    selectedModel: .constant("openai/gpt-5.3-codex"),
    selectedEffort: .constant(.default),
    models: [
      ServerCodexModelOption(
        id: "1", model: "openai/gpt-5.3-codex",
        displayName: "GPT-5.3 Codex",
        description: "Latest frontier agentic coding model.",
        isDefault: true,
        supportedReasoningEfforts: ["low", "medium", "high", "xhigh"]
      ),
      ServerCodexModelOption(
        id: "2", model: "openai/gpt-5.1-codex-max",
        displayName: "GPT-5.1 Codex Max",
        description: "Codex-optimized flagship for deep and fast reasoning.",
        isDefault: false,
        supportedReasoningEfforts: ["low", "medium", "high", "xhigh"]
      ),
      ServerCodexModelOption(
        id: "3", model: "openai/gpt-5.1-codex-mini",
        displayName: "GPT-5.1 Codex Mini",
        description: "Cheaper and faster model tuned for coding loops.",
        isDefault: false,
        supportedReasoningEfforts: ["minimal", "low", "medium"]
      ),
      ServerCodexModelOption(
        id: "4", model: "anthropic/claude-sonnet-4",
        displayName: "Claude Sonnet 4",
        description: "Strong planning model for longer implementation tasks.",
        isDefault: false,
        supportedReasoningEfforts: ["low", "medium", "high"]
      ),
    ]
  )
}
