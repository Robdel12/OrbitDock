//
//  CodexInputBar.swift
//  OrbitDock
//
//  Message input UI for direct Codex sessions.
//  Allows users to send prompts directly from OrbitDock.
//

import SwiftUI

struct CodexInputBar: View {
  let sessionId: String
  @Binding var selectedSkills: Set<String>
  var onOpenSkills: (() -> Void)? = nil

  @Environment(ServerAppState.self) private var serverState

  @State private var message = ""
  @State private var isSending = false
  @State private var errorMessage: String?
  @State private var showConfig = false
  @State private var selectedModel: String = ""
  @State private var selectedEffort: EffortLevel = .default
  @State private var completionActive = false
  @State private var completionQuery = ""
  @State private var completionIndex = 0
  @FocusState private var isFocused: Bool

  private var isSessionWorking: Bool {
    serverState.sessions.first(where: { $0.id == sessionId })?.workStatus == .working
  }

  private var hasOverrides: Bool {
    selectedEffort != .default
  }

  private var availableSkills: [ServerSkillMetadata] {
    (serverState.sessionSkills[sessionId] ?? []).filter { $0.enabled }
  }

  private var filteredSkills: [ServerSkillMetadata] {
    guard !completionQuery.isEmpty else { return availableSkills }
    let q = completionQuery.lowercased()
    return availableSkills.filter { $0.name.lowercased().contains(q) }
  }

  private var shouldShowCompletion: Bool {
    completionActive && !filteredSkills.isEmpty
  }

  private var hasInlineSkills: Bool {
    let names = Set(availableSkills.map { $0.name })
    return message.components(separatedBy: .whitespacesAndNewlines).contains { word in
      word.hasPrefix("$") && names.contains(String(word.dropFirst()))
    }
  }

  private var modelOptions: [ServerCodexModelOption] {
    serverState.codexModels
  }

  private var defaultModelSelection: String {
    if let current = serverState.sessions.first(where: { $0.id == sessionId })?.model,
       modelOptions.contains(where: { $0.model == current })
    {
      return current
    }
    if let model = modelOptions.first(where: { $0.isDefault && !$0.model.isEmpty })?.model {
      return model
    }
    return modelOptions.first(where: { !$0.model.isEmpty })?.model ?? ""
  }

  var body: some View {
    VStack(spacing: 0) {
      Divider()

      // Collapsible config row (hidden when steering)
      if showConfig, !isSessionWorking {
        HStack(spacing: 20) {
          // Model picker
          HStack(spacing: 6) {
            Text("Model")
              .font(.caption)
              .foregroundStyle(.tertiary)
            Picker("Model", selection: $selectedModel) {
              ForEach(modelOptions.filter { !$0.model.isEmpty }, id: \.id) { model in
                Text(model.displayName).tag(model.model)
              }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
          }

          // Effort picker
          HStack(spacing: 6) {
            Text("Effort")
              .font(.caption)
              .foregroundStyle(.tertiary)
            Picker("Effort", selection: $selectedEffort) {
              ForEach(EffortLevel.allCases) { level in
                Text(level.displayName).tag(level)
              }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
          }

          Spacer()

          // Reset button when overrides are active
          if hasOverrides {
            Button {
              withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                selectedEffort = .default
              }
            } label: {
              Text("Reset")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.backgroundPrimary.opacity(0.4))
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      // Inline $ skill completion (hidden when steering)
      if shouldShowCompletion, !isSessionWorking {
        SkillCompletionList(
          skills: filteredSkills,
          selectedIndex: completionIndex,
          query: completionQuery,
          onSelect: acceptSkillCompletion
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      HStack(spacing: 12) {
        if !isSessionWorking {
          // Config toggle
          Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
              showConfig.toggle()
            }
          } label: {
            Image(systemName: "slider.horizontal.3")
              .font(.system(size: 14))
              .foregroundStyle(hasOverrides ? Color.accent : .secondary)
          }
          .buttonStyle(.plain)
          .help("Per-turn config overrides")

          // Skills - opens sidebar skills tab
          Button {
            serverState.listSkills(sessionId: sessionId)
            onOpenSkills?()
          } label: {
            Image(systemName: "bolt.fill")
              .font(.system(size: 14))
              .foregroundStyle(!selectedSkills.isEmpty || hasInlineSkills ? Color.accent : .secondary)
          }
          .buttonStyle(.plain)
          .help("Attach skills")
        }

        // Text field
        TextField(isSessionWorking ? "Steer the current turn..." : "Send a message...", text: $message, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(1 ... 5)
          .focused($isFocused)
          .disabled(isSending)
          .onChange(of: message) { _, newValue in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
              updateSkillCompletion(newValue)
            }
          }
          .onKeyPress(phases: .down) { keyPress in
            handleCompletionKeyPress(keyPress)
          }
          .onSubmit {
            if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              sendMessage()
            }
          }

        if !isSessionWorking {
          // Override indicator (when collapsed and overrides active)
          if !showConfig, hasOverrides {
            overrideBadge
          }

          // Skills badge
          if !selectedSkills.isEmpty {
            Text("\(selectedSkills.count) skill\(selectedSkills.count == 1 ? "" : "s")")
              .font(.caption2)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.accent.opacity(0.15))
              .foregroundStyle(Color.accent)
              .clipShape(Capsule())
          }
        }

        // Send button
        Button(action: sendMessage) {
          Group {
            if isSending {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: isSessionWorking ? "arrow.uturn.right.circle.fill" : "arrow.up.circle.fill")
                .font(.title2)
            }
          }
          .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(canSend ? Color.accent : Color.secondary)
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: .command)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      // Error message
      if let error = errorMessage {
        HStack {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text(error)
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Dismiss") {
            errorMessage = nil
          }
          .buttonStyle(.plain)
          .font(.caption)
          .foregroundStyle(Color.accent)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
      }
    }
    .background(Color.backgroundSecondary)
    .onAppear {
      serverState.refreshCodexModels()
      if selectedModel.isEmpty {
        selectedModel = defaultModelSelection
      }
    }
    .onChange(of: serverState.codexModels.count) { _, _ in
      if selectedModel.isEmpty || !modelOptions.contains(where: { $0.model == selectedModel }) {
        selectedModel = defaultModelSelection
      }
    }
  }

  @ViewBuilder
  private var overrideBadge: some View {
    let parts = [
      selectedEffort != .default ? selectedEffort.displayName : nil,
    ].compactMap { $0 }

    if !parts.isEmpty {
      Text(parts.joined(separator: " · "))
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.accent.opacity(0.15))
        .foregroundStyle(Color.accent)
        .clipShape(Capsule())
    }
  }

  private var canSend: Bool {
    let hasContent = !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if isSessionWorking { return !isSending && hasContent }
    return !isSending && hasContent && !selectedModel.isEmpty
  }

  private func sendMessage() {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isSending else { return }

    if isSessionWorking {
      serverState.steerTurn(sessionId: sessionId, content: trimmed)
      message = ""
      return
    }

    guard !selectedModel.isEmpty else {
      errorMessage = "No model available yet. Wait for model list to load."
      return
    }

    let effort = selectedEffort == .default ? nil : selectedEffort.rawValue

    // Extract inline $skill-name references from message
    let inlineSkillNames = extractInlineSkillNames(from: trimmed)

    // Combine popover-selected skills with inline $ skills (deduplicated)
    var skillPaths = selectedSkills
    for name in inlineSkillNames {
      if let skill = availableSkills.first(where: { $0.name == name }) {
        skillPaths.insert(skill.path)
      }
    }
    let skillInputs = skillPaths.compactMap { path -> ServerSkillInput? in
      guard let skill = availableSkills.first(where: { $0.path == path }) else { return nil }
      return ServerSkillInput(name: skill.name, path: skill.path)
    }

    // Send full message (keep $tokens for context) with skills array
    serverState.sendMessage(sessionId: sessionId, content: trimmed, model: selectedModel, effort: effort, skills: skillInputs)
    message = ""
  }

  // MARK: - Inline Skill Completion

  private func updateSkillCompletion(_ text: String) {
    guard let dollarIdx = text.lastIndex(of: "$") else {
      completionActive = false
      return
    }

    let afterDollar = text[text.index(after: dollarIdx)...]

    // Dismiss if there's whitespace after the last $
    if afterDollar.contains(where: { $0.isWhitespace }) {
      completionActive = false
      return
    }

    let query = String(afterDollar)

    // Don't re-trigger when the query exactly matches a skill name (already accepted)
    if availableSkills.contains(where: { $0.name == query }) {
      completionActive = false
      return
    }

    // Ensure skills are loaded
    if availableSkills.isEmpty {
      serverState.listSkills(sessionId: sessionId)
    }

    completionQuery = query
    completionIndex = 0
    completionActive = true
  }

  private func acceptSkillCompletion(_ skill: ServerSkillMetadata) {
    // Replace $query with $full-skill-name (keep token visible in text)
    if let dollarIdx = message.lastIndex(of: "$") {
      let prefix = String(message[..<dollarIdx])
      message = prefix + "$" + skill.name + " "
    }
    completionActive = false
    completionQuery = ""
    completionIndex = 0
    isFocused = true
  }

  private func extractInlineSkillNames(from text: String) -> [String] {
    let skillNameSet = Set(availableSkills.map { $0.name })
    var names: [String] = []

    for word in text.components(separatedBy: .whitespacesAndNewlines) {
      guard word.hasPrefix("$") else { continue }
      // Strip trailing punctuation (e.g., "$skill-name?" or "$skill-name,")
      let raw = String(word.dropFirst())
      let name = raw.trimmingCharacters(in: .punctuationCharacters)
      if skillNameSet.contains(name) {
        names.append(name)
      }
    }

    return names
  }

  private func handleCompletionKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
    if keyPress.key == .escape {
      guard completionActive else { return .ignored }
      completionActive = false
      return .handled
    }

    guard shouldShowCompletion else { return .ignored }

    // Arrow keys
    if keyPress.key == .upArrow {
      completionIndex = max(0, completionIndex - 1)
      return .handled
    } else if keyPress.key == .downArrow {
      completionIndex = min(filteredSkills.count - 1, completionIndex + 1)
      return .handled
    }

    // Emacs bindings: C-n (next) / C-p (previous)
    if keyPress.modifiers.contains(.control) {
      if keyPress.key == KeyEquivalent("n") {
        completionIndex = min(filteredSkills.count - 1, completionIndex + 1)
        return .handled
      } else if keyPress.key == KeyEquivalent("p") {
        completionIndex = max(0, completionIndex - 1)
        return .handled
      }
    }

    // Accept completion
    if keyPress.key == .return || keyPress.key == .tab {
      acceptSkillCompletion(filteredSkills[completionIndex])
      return .handled
    }

    return .ignored
  }
}

// MARK: - Interrupt Button

struct CodexInterruptButton: View {
  let sessionId: String
  @Environment(ServerAppState.self) private var serverState

  @State private var isInterrupting = false

  var body: some View {
    Button(action: interrupt) {
      HStack(spacing: 4) {
        if isInterrupting {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: "stop.fill")
        }
        Text("Stop")
      }
      .font(.caption)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Color.statusError.opacity(0.2))
      .foregroundStyle(Color.statusError)
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
    .disabled(isInterrupting)
  }

  private func interrupt() {
    serverState.interruptSession(sessionId)
  }
}

// MARK: - Skill Completion List

private struct SkillCompletionList: View {
  let skills: [ServerSkillMetadata]
  let selectedIndex: Int
  let query: String
  let onSelect: (ServerSkillMetadata) -> Void

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(skills.prefix(8).enumerated()), id: \.element.id) { index, skill in
            Button { onSelect(skill) } label: {
              HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                  .font(.caption2)
                  .foregroundStyle(Color.accent)
                  .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                  skillNameView(skill.name)
                  if let desc = skill.shortDescription ?? Optional(skill.description), !desc.isEmpty {
                    Text(desc)
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                }
                Spacer()
              }
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(index == selectedIndex ? Color.accent.opacity(0.15) : Color.clear)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(index)
          }
        }
      }
      .scrollIndicators(.hidden)
      .onChange(of: selectedIndex) { _, newIndex in
        proxy.scrollTo(newIndex, anchor: .center)
      }
    }
    .frame(maxHeight: 200)
    .background(Color.backgroundPrimary)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .shadow(color: .black.opacity(0.3), radius: 8, y: -2)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
    )
  }

  @ViewBuilder
  private func skillNameView(_ name: String) -> some View {
    if !query.isEmpty, let range = name.range(of: query, options: .caseInsensitive) {
      let before = String(name[name.startIndex ..< range.lowerBound])
      let match = String(name[range])
      let after = String(name[range.upperBound...])
      (Text(before) + Text(match).foregroundStyle(Color.accent) + Text(after))
        .font(.callout.weight(.medium))
    } else {
      Text(name)
        .font(.callout.weight(.medium))
    }
  }
}

#Preview {
  @Previewable @State var skills: Set<String> = []
  CodexInputBar(sessionId: "test-session", selectedSkills: $skills)
    .environment(ServerAppState())
    .frame(width: 400)
}
