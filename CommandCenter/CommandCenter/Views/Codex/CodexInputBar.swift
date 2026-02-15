//
//  CodexInputBar.swift
//  OrbitDock
//
//  Unified instrument panel for direct Codex sessions.
//  Three layers: token strip → composer → instrument strip.
//

import SwiftUI
import UniformTypeIdentifiers

struct InstrumentPanel: View {
  let session: Session
  @Binding var selectedSkills: Set<String>
  @Binding var isPinned: Bool
  @Binding var unreadCount: Int
  @Binding var scrollToBottomTrigger: Int
  @Binding var showApprovalHistory: Bool
  var onOpenSkills: (() -> Void)? = nil

  @Environment(ServerAppState.self) private var serverState

  @State private var message = ""
  @State private var isSending = false
  @State private var errorMessage: String?
  @State private var selectedModel: String = ""
  @State private var selectedEffort: EffortLevel = .default
  @State private var showModelEffortPopover = false
  @State private var completionActive = false
  @State private var completionQuery = ""
  @State private var completionIndex = 0
  @FocusState private var isFocused: Bool

  // Attachments
  @State private var fileIndex = ProjectFileIndex()
  @State private var attachedImages: [AttachedImage] = []
  @State private var attachedMentions: [AttachedMention] = []
  @State private var mentionActive = false
  @State private var mentionQuery = ""
  @State private var mentionIndex = 0

  // Input mode
  @State private var manualReviewMode = false

  private var sessionId: String { session.id }

  private var inputMode: InputMode {
    if manualReviewMode { return .reviewNotes }
    if isSessionWorking { return .steer }
    return .prompt
  }

  private var composerBorderColor: Color {
    switch inputMode {
    case .steer: .composerSteer
    case .reviewNotes: .composerReview
    default: .composerPrompt
    }
  }

  private var isSessionWorking: Bool {
    session.workStatus == .working
  }

  private var isSessionActive: Bool {
    session.isActive
  }

  private var hasOverrides: Bool {
    selectedEffort != .default || selectedModel != defaultModelSelection
  }

  private var availableSkills: [ServerSkillMetadata] {
    serverState.session(sessionId).skills.filter { $0.enabled }
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
    if let current = session.model,
       modelOptions.contains(where: { $0.model == current })
    {
      return current
    }
    if let model = modelOptions.first(where: { $0.isDefault && !$0.model.isEmpty })?.model {
      return model
    }
    return modelOptions.first(where: { !$0.model.isEmpty })?.model ?? ""
  }

  private var projectPath: String? {
    session.projectPath
  }

  private var filteredFiles: [ProjectFileIndex.ProjectFile] {
    guard let path = projectPath else { return [] }
    return fileIndex.search(mentionQuery, in: path)
  }

  private var shouldShowMentionCompletion: Bool {
    mentionActive && !filteredFiles.isEmpty
  }

  private var hasAttachments: Bool {
    !attachedImages.isEmpty || !attachedMentions.isEmpty
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      // ━━━ Token Progress Strip (2px full-width) ━━━
      if session.hasTokenUsage {
        tokenStrip
      }

      // ━━━ Approval / Question UI ━━━
      if session.canApprove {
        CodexApprovalView(session: session)
          .padding(.horizontal, Spacing.lg)
          .padding(.vertical, Spacing.sm)
      } else if session.canAnswer {
        CodexQuestionView(session: session)
          .padding(.horizontal, Spacing.lg)
          .padding(.vertical, Spacing.sm)
      }

      if showApprovalHistory {
        CodexApprovalHistoryView(sessionId: sessionId)
          .padding(.horizontal, Spacing.lg)
          .padding(.bottom, Spacing.sm)
      }

      // ━━━ Review notes indicator (only for review mode) ━━━
      if isSessionActive, inputMode == .reviewNotes {
        HStack(spacing: 8) {
          HStack(spacing: 6) {
            Circle()
              .fill(Color.composerReview)
              .frame(width: 6, height: 6)
            Text("Review Notes")
              .font(.system(size: TypeScale.body, weight: .medium))
              .foregroundStyle(Color.composerReview)
          }
          Spacer()
          Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
              manualReviewMode.toggle()
            }
          } label: {
            Text("Cancel")
              .font(.system(size: TypeScale.body, weight: .medium))
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.lg)
        .frame(height: 24)
        .background(Color.backgroundTertiary)
      }

      // ━━━ Skill completion ━━━
      if shouldShowCompletion, !isSessionWorking {
        SkillCompletionList(
          skills: filteredSkills,
          selectedIndex: completionIndex,
          query: completionQuery,
          onSelect: acceptSkillCompletion
        )
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.xs)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      // ━━━ Mention completion ━━━
      if shouldShowMentionCompletion, !isSessionWorking {
        MentionCompletionList(
          files: filteredFiles,
          selectedIndex: mentionIndex,
          query: mentionQuery,
          onSelect: acceptMentionCompletion
        )
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.xs)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      // ━━━ Attachment bar ━━━
      if hasAttachments {
        AttachmentBar(images: $attachedImages, mentions: $attachedMentions)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      // ━━━ Composer area ━━━
      if isSessionActive {
        composerRow
      } else {
        // Ended session — resume button
        resumeRow
      }

      // ━━━ Error message ━━━
      if let error = errorMessage {
        errorRow(error)
      }

      // ━━━ Instrument strip (bottom) ━━━
      if isSessionActive {
        instrumentStrip
      }
    }
    .background(Color.backgroundSecondary)
    .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
      handleDrop(providers)
    }
    .onAppear {
      serverState.refreshCodexModels()
      if selectedModel.isEmpty {
        selectedModel = defaultModelSelection
      }
      if let path = projectPath {
        Task { await fileIndex.loadIfNeeded(path) }
      }
    }
    .onChange(of: serverState.codexModels.count) { _, _ in
      if selectedModel.isEmpty || !modelOptions.contains(where: { $0.model == selectedModel }) {
        selectedModel = defaultModelSelection
      }
    }
  }

  // MARK: - Token Progress Strip

  private var tokenStrip: some View {
    let pct = tokenContextPercentage
    let color: Color = pct > 0.9 ? .statusError : pct > 0.7 ? .statusReply : .accent

    return GeometryReader { geo in
      ZStack(alignment: .leading) {
        Rectangle().fill(color.opacity(OpacityTier.subtle))
        Rectangle()
          .fill(
            LinearGradient(
              colors: [color.opacity(0.7), color],
              startPoint: .leading,
              endPoint: .trailing
            )
          )
          .frame(width: geo.size.width * pct)
          .shadow(color: color.opacity(0.6), radius: 4, y: 0)
      }
    }
    .frame(height: 3)
    .help(tokenTooltipText)
  }

  private var tokenContextPercentage: Double {
    guard let window = session.codexContextWindow, window > 0,
          let input = session.codexInputTokens
    else { return 0 }
    return min(1.0, Double(input) / Double(window))
  }

  private var tokenTooltipText: String {
    var parts: [String] = []
    if let input = session.codexInputTokens {
      parts.append("Input: \(formatTokenCount(input))")
    }
    if let output = session.codexOutputTokens {
      parts.append("Output: \(formatTokenCount(output))")
    }
    if let cached = session.codexCachedTokens, cached > 0,
       let input = session.codexInputTokens, input > 0
    {
      let percent = Int(Double(cached) / Double(input) * 100)
      parts.append("Cached: \(formatTokenCount(cached)) (\(percent)% savings)")
    }
    if let window = session.codexContextWindow {
      parts.append("Context: \(formatTokenCount(window))")
    }
    return parts.isEmpty ? "Token usage" : parts.joined(separator: "\n")
  }

  private func formatTokenCount(_ count: Int) -> String {
    if count >= 1_000_000 {
      return String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
      return String(format: "%.1fk", Double(count) / 1_000)
    }
    return "\(count)"
  }

  // MARK: - Composer Row

  private var composerRow: some View {
    HStack(spacing: Spacing.sm) {
      // Text field inside bordered container with mode tint
      HStack(spacing: Spacing.sm) {
        // Mode badge embedded in the composer
        if isSessionWorking {
          Text("STEER")
            .font(.system(size: 9, weight: .black, design: .monospaced))
            .foregroundStyle(Color.composerSteer)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.composerSteer.opacity(OpacityTier.light), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }

        TextField(isSessionWorking ? "Steer the current turn..." : "Send a message...", text: $message, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(1 ... 5)
          .focused($isFocused)
          .disabled(isSending)
          .onChange(of: message) { _, newValue in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
              updateSkillCompletion(newValue)
              updateMentionCompletion(newValue)
            }
          }
          .onKeyPress(phases: .down) { keyPress in
            // Shift+Return inserts a newline instead of sending
            if keyPress.key == .return, keyPress.modifiers.contains(.shift) {
              message += "\n"
              return .handled
            }
            if keyPress.modifiers.contains(.command), keyPress.key == KeyEquivalent("v") {
              if pasteImageFromClipboard() {
                return .handled
              }
            }
            return handleCompletionKeyPress(keyPress)
          }
          .onSubmit {
            let hasContent = !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasContent || hasAttachments {
              sendMessage()
            }
          }

        // Override badges (inside border)
        if !isSessionWorking {
          if hasOverrides {
            overrideBadge
          }
          if !selectedSkills.isEmpty {
            Text("\(selectedSkills.count) skill\(selectedSkills.count == 1 ? "" : "s")")
              .font(.system(size: TypeScale.micro, weight: .bold))
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.accent.opacity(0.15))
              .foregroundStyle(Color.accent)
              .clipShape(Capsule())
          }
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, 10)
      .background(
        RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
          .fill(composerBorderColor.opacity(0.04))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
          .strokeBorder(composerBorderColor.opacity(0.35), lineWidth: 1.5)
      )

      // Send button — larger, with glow when active
      Button(action: sendMessage) {
        Group {
          if isSending {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: isSessionWorking ? "arrow.uturn.right" : "arrow.up")
              .font(.system(size: TypeScale.subhead, weight: .bold))
              .foregroundStyle(.white)
          }
        }
        .frame(width: 30, height: 30)
        .background(
          Circle().fill(canSend ? composerBorderColor : Color.surfaceHover)
        )
        .shadow(color: canSend ? composerBorderColor.opacity(0.4) : .clear, radius: 6, y: 0)
      }
      .buttonStyle(.plain)
      .disabled(!canSend)
      .keyboardShortcut(.return, modifiers: .command)
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
  }

  // MARK: - Composer Action Button

  private var modelEffortControlButton: some View {
    Button {
      showModelEffortPopover.toggle()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "slider.horizontal.3")
          .font(.system(size: 13, weight: .semibold))

        Text("Model")
          .font(.system(size: TypeScale.caption, weight: .semibold))

        Text(selectedEffort.displayName.uppercased())
          .font(.system(size: 8, weight: .bold, design: .monospaced))
          .foregroundStyle(selectedEffort == .default ? Color.accent : selectedEffort.color)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(
            (selectedEffort == .default ? Color.accent : selectedEffort.color).opacity(0.15),
            in: Capsule()
          )
      }
      .foregroundStyle(hasOverrides ? Color.accent : Color.textSecondary)
      .padding(.horizontal, Spacing.sm)
      .frame(height: 28)
      .background(
        hasOverrides ? Color.accent.opacity(OpacityTier.light) : Color.surfaceHover,
        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
      )
    }
    .buttonStyle(.plain)
    .fixedSize()
    .help("Model and reasoning effort")
    .popover(isPresented: $showModelEffortPopover, arrowEdge: .bottom) {
      ModelEffortPopover(
        selectedModel: $selectedModel,
        selectedEffort: $selectedEffort,
        models: modelOptions
      )
    }
  }

  private func composerActionButton(
    icon: String,
    isActive: Bool,
    help: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(isActive ? Color.accent : .secondary)
        .frame(width: 28, height: 28)
        .background(
          isActive ? Color.accent.opacity(OpacityTier.light) : Color.surfaceHover,
          in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        )
    }
    .buttonStyle(.plain)
    .help(help)
  }

  // MARK: - Instrument Strip

  private var instrumentStrip: some View {
    HStack(spacing: 0) {
      // ━━━ Left segment: Interrupt + Actions ━━━
      HStack(spacing: Spacing.sm) {
        if !isSessionWorking {
          modelEffortControlButton

          composerActionButton(
            icon: "bolt.fill",
            isActive: !selectedSkills.isEmpty || hasInlineSkills,
            help: "Attach skills"
          ) {
            serverState.listSkills(sessionId: sessionId)
            onOpenSkills?()
          }

          composerActionButton(
            icon: "paperclip",
            isActive: !attachedImages.isEmpty,
            help: "Attach images"
          ) {
            pickImages()
          }

          Color.panelBorder.frame(width: 1, height: 16)
        }

        // Interrupt button (prominent when working)
        if session.workStatus == .working {
          CodexInterruptButton(sessionId: sessionId)
        }

        // Action buttons — individual, not cramped
        stripButton(icon: "arrow.uturn.backward", help: "Undo last turn", disabled: serverState.session(sessionId).undoInProgress) {
          serverState.undoLastTurn(sessionId: sessionId)
        }

        stripButton(icon: "arrow.triangle.branch", help: "Fork conversation", disabled: serverState.session(sessionId).forkInProgress) {
          serverState.forkSession(sessionId: sessionId)
        }

        if session.hasTokenUsage {
          stripButton(icon: "arrow.triangle.2.circlepath", help: "Compact context") {
            serverState.compactContext(sessionId: sessionId)
          }
        }
      }
      .padding(.horizontal, Spacing.md)

      // Segment divider
      Color.panelBorder.frame(width: 1, height: 16)

      // ━━━ Center segment: Autonomy + Approvals ━━━
      HStack(spacing: Spacing.sm) {
        AutonomyPill(sessionId: sessionId)

        if approvalHistoryCount > 0 {
          Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
              showApprovalHistory.toggle()
            }
          } label: {
            HStack(spacing: 4) {
              Image(systemName: "checkmark.shield.fill")
                .font(.system(size: TypeScale.body, weight: .medium))
              Text("\(approvalHistoryCount)")
                .font(.system(size: TypeScale.body, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(showApprovalHistory ? Color.accent : .secondary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
              showApprovalHistory ? Color.accent.opacity(OpacityTier.light) : Color.clear,
              in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            )
          }
          .buttonStyle(.plain)
          .help("Approval history")
        }
      }
      .padding(.horizontal, Spacing.md)

      // Segment divider
      Color.panelBorder.frame(width: 1, height: 16)

      // ━━━ Token summary + model (inline) ━━━
      if session.hasTokenUsage {
        HStack(spacing: 6) {
          let pct = Int(tokenContextPercentage * 100)
          let color: Color = pct > 90 ? .statusError : pct > 70 ? .statusReply : .accent
          Text("\(pct)%")
            .font(.system(size: TypeScale.body, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
          if let input = session.codexInputTokens {
            Text(formatTokenCount(input))
              .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
              .foregroundStyle(.tertiary)
          }
        }
        .padding(.horizontal, Spacing.md)
        .help(tokenTooltipText)

        if !selectedModel.isEmpty {
          HStack(spacing: 6) {
            Text(shortModelName(selectedModel))
              .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textTertiary)
              .lineLimit(1)

            Text(selectedEffort.displayName.uppercased())
              .font(.system(size: 8, weight: .bold, design: .monospaced))
              .foregroundStyle(selectedEffort == .default ? Color.accent : selectedEffort.color)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(
                (selectedEffort == .default ? Color.accent : selectedEffort.color).opacity(0.15),
                in: Capsule()
              )
          }
          .padding(.horizontal, Spacing.sm)
          .help("Model: \(selectedModel)\nEffort: \(selectedEffort.displayName)")
        }

        Color.panelBorder.frame(width: 1, height: 16)
      }

      // ━━━ Branch info ━━━
      if let branch = session.branch, !branch.isEmpty {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "arrow.triangle.branch")
            .font(.system(size: TypeScale.caption, weight: .medium))
          Text(branch)
            .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
            .lineLimit(1)
        }
        .foregroundStyle(Color.gitBranch.opacity(0.75))
        .padding(.horizontal, Spacing.sm)
        .help(branch)

        Color.panelBorder.frame(width: 1, height: 16)
      }

      // ━━━ CWD (when different from project root) ━━━
      if let cwd = session.currentCwd,
         !cwd.isEmpty,
         cwd != session.projectPath
      {
        let displayCwd = cwd.hasPrefix(session.projectPath + "/")
          ? "./" + cwd.dropFirst(session.projectPath.count + 1)
          : cwd

        HStack(spacing: Spacing.xs) {
          Image(systemName: "folder")
            .font(.system(size: TypeScale.caption, weight: .medium))
          Text(displayCwd)
            .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
            .lineLimit(1)
        }
        .foregroundStyle(Color.textTertiary)
        .padding(.horizontal, Spacing.sm)
        .help(cwd)

        Color.panelBorder.frame(width: 1, height: 16)
      }

      Spacer()

      // ━━━ Right segment: Follow state + Time ━━━
      HStack(spacing: Spacing.sm) {
        // Unread badge
        if !isPinned, unreadCount > 0 {
          Button {
            isPinned = true
            unreadCount = 0
            scrollToBottomTrigger += 1
          } label: {
            HStack(spacing: 3) {
              Image(systemName: "arrow.down")
                .font(.system(size: TypeScale.caption, weight: .bold))
              Text("\(unreadCount)")
                .font(.system(size: TypeScale.body, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
            .background(Color.accent, in: Capsule())
          }
          .buttonStyle(.plain)
        }

        // Follow toggle
        Button {
          isPinned.toggle()
          if isPinned {
            unreadCount = 0
            scrollToBottomTrigger += 1
          }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: isPinned ? "arrow.down.to.line" : "pause.fill")
              .font(.system(size: TypeScale.body, weight: .semibold))
            Text(isPinned ? "Following" : "Paused")
              .font(.system(size: TypeScale.body, weight: .medium))
          }
          .foregroundStyle(isPinned ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.statusReply))
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)
          .background(
            isPinned ? Color.clear : Color.statusReply.opacity(OpacityTier.light),
            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          )
        }
        .buttonStyle(.plain)

        // Relative time
        if let lastActivity = session.lastActivityAt {
          Text(lastActivity, style: .relative)
            .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
            .foregroundStyle(.quaternary)
        }
      }
      .padding(.horizontal, Spacing.md)
      .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isPinned)
      .animation(.spring(response: 0.25, dampingFraction: 0.8), value: unreadCount)
    }
    .frame(height: 32)
    .padding(.bottom, Spacing.sm)
    .background(Color.backgroundTertiary.opacity(0.5))
  }

  // MARK: - Strip Button

  @State private var stripHover: String?

  private func stripButton(
    icon: String,
    help: String,
    disabled: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: TypeScale.code, weight: .medium))
        .foregroundStyle(disabled ? AnyShapeStyle(.quaternary) : stripHover == icon ? AnyShapeStyle(Color.accent) : AnyShapeStyle(.secondary))
        .frame(width: 26, height: 26)
        .background(
          stripHover == icon ? Color.surfaceHover : Color.clear,
          in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        )
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .help(help)
    .onHover { hovering in
      stripHover = hovering ? icon : (stripHover == icon ? nil : stripHover)
    }
  }

  // MARK: - Resume Row (ended session)

  private var resumeRow: some View {
    HStack {
      Button {
        serverState.resumeSession(sessionId)
      } label: {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "arrow.counterclockwise")
            .font(.system(size: TypeScale.code, weight: .medium))
          Text("Resume")
            .font(.system(size: TypeScale.code, weight: .medium))
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.accent.opacity(OpacityTier.light), in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .foregroundStyle(Color.accent)
      }
      .buttonStyle(.plain)

      Spacer()

      if let lastActivity = session.lastActivityAt {
        Text(lastActivity, style: .relative)
          .font(.system(size: TypeScale.body, design: .monospaced))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
  }

  // MARK: - Error Row

  private func errorRow(_ error: String) -> some View {
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
    .padding(.horizontal, Spacing.lg)
    .padding(.bottom, Spacing.sm)
  }

  // MARK: - Helpers

  private func shortModelName(_ model: String) -> String {
    // Strip common prefixes to get a compact display name
    let name = model
      .replacingOccurrences(of: "openai/", with: "")
      .replacingOccurrences(of: "anthropic/", with: "")
    // If it's already short (like "o3"), return as-is
    if name.count <= 8 { return name }
    // Take first component before a dash if very long
    let parts = name.split(separator: "-", maxSplits: 2)
    if parts.count >= 2 {
      return String(parts[0]) + "-" + String(parts[1])
    }
    return name
  }

  private var approvalHistoryCount: Int {
    serverState.session(sessionId).approvalHistory.count
  }

  @ViewBuilder
  private var overrideBadge: some View {
    let parts = [
      selectedModel != defaultModelSelection ? shortModelName(selectedModel) : nil,
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
    return !isSending && (hasContent || hasAttachments) && !selectedModel.isEmpty
  }

  private func sendMessage() {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !isSending else { return }
    guard !trimmed.isEmpty || hasAttachments else { return }

    if isSessionWorking {
      guard !trimmed.isEmpty else { return }
      serverState.steerTurn(sessionId: sessionId, content: trimmed)
      message = ""
      return
    }

    guard !selectedModel.isEmpty else {
      errorMessage = "No model available yet. Wait for model list to load."
      return
    }

    let effort = selectedEffort.serialized

    var expandedContent = trimmed
    for mention in attachedMentions {
      expandedContent = expandedContent.replacingOccurrences(of: "@\(mention.name)", with: mention.path)
    }

    let inlineSkillNames = extractInlineSkillNames(from: expandedContent)

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

    let imageInputs = attachedImages.map { $0.serverInput }

    serverState.sendMessage(
      sessionId: sessionId,
      content: expandedContent,
      model: selectedModel,
      effort: effort,
      skills: skillInputs,
      images: imageInputs
    )
    message = ""
    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
      attachedImages = []
      attachedMentions = []
    }
  }

  // MARK: - Inline Skill Completion

  private func updateSkillCompletion(_ text: String) {
    guard let dollarIdx = text.lastIndex(of: "$") else {
      completionActive = false
      return
    }

    let afterDollar = text[text.index(after: dollarIdx)...]

    if afterDollar.contains(where: { $0.isWhitespace }) {
      completionActive = false
      return
    }

    let query = String(afterDollar)

    if availableSkills.contains(where: { $0.name == query }) {
      completionActive = false
      return
    }

    if availableSkills.isEmpty {
      serverState.listSkills(sessionId: sessionId)
    }

    completionQuery = query
    completionIndex = 0
    completionActive = true
  }

  private func acceptSkillCompletion(_ skill: ServerSkillMetadata) {
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
      let raw = String(word.dropFirst())
      let name = raw.trimmingCharacters(in: .punctuationCharacters)
      if skillNameSet.contains(name) {
        names.append(name)
      }
    }

    return names
  }

  // MARK: - @ Mention Completion

  private func updateMentionCompletion(_ text: String) {
    guard let atIdx = text.lastIndex(of: "@") else {
      mentionActive = false
      return
    }

    if atIdx != text.startIndex {
      let before = text[text.index(before: atIdx)]
      if !before.isWhitespace {
        mentionActive = false
        return
      }
    }

    let afterAt = text[text.index(after: atIdx)...]

    if afterAt.contains(where: { $0.isWhitespace }) {
      mentionActive = false
      return
    }

    let query = String(afterAt)

    if attachedMentions.contains(where: { $0.name == query || $0.path.hasSuffix(query) }) {
      mentionActive = false
      return
    }

    mentionQuery = query
    mentionIndex = 0
    mentionActive = true

    if let path = projectPath {
      Task { await fileIndex.loadIfNeeded(path) }
    }
  }

  private func acceptMentionCompletion(_ file: ProjectFileIndex.ProjectFile) {
    if let atIdx = message.lastIndex(of: "@") {
      let prefix = String(message[..<atIdx])
      message = prefix + "@" + file.name + " "
    }
    mentionActive = false
    mentionQuery = ""
    mentionIndex = 0
    isFocused = true

    guard !attachedMentions.contains(where: { $0.id == file.id }) else { return }
    let absolutePath = if let base = projectPath {
      (base as NSString).appendingPathComponent(file.relativePath)
    } else {
      file.relativePath
    }
    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
      attachedMentions.append(AttachedMention(id: file.id, name: file.name, path: absolutePath))
    }
  }

  // MARK: - Keyboard Navigation

  private func handleCompletionKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
    if keyPress.key == .escape {
      if mentionActive {
        mentionActive = false
        return .handled
      }
      guard completionActive else { return .ignored }
      completionActive = false
      return .handled
    }

    if shouldShowMentionCompletion {
      return handleMentionKeyPress(keyPress)
    }

    guard shouldShowCompletion else { return .ignored }

    if keyPress.key == .upArrow {
      completionIndex = max(0, completionIndex - 1)
      return .handled
    } else if keyPress.key == .downArrow {
      completionIndex = min(filteredSkills.count - 1, completionIndex + 1)
      return .handled
    }

    if keyPress.modifiers.contains(.control) {
      if keyPress.key == KeyEquivalent("n") {
        completionIndex = min(filteredSkills.count - 1, completionIndex + 1)
        return .handled
      } else if keyPress.key == KeyEquivalent("p") {
        completionIndex = max(0, completionIndex - 1)
        return .handled
      }
    }

    if keyPress.key == .return || keyPress.key == .tab {
      acceptSkillCompletion(filteredSkills[completionIndex])
      return .handled
    }

    return .ignored
  }

  private func handleMentionKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
    let maxIndex = filteredFiles.count - 1
    guard maxIndex >= 0 else { return .ignored }

    if keyPress.key == .upArrow {
      mentionIndex = max(0, mentionIndex - 1)
      return .handled
    } else if keyPress.key == .downArrow {
      mentionIndex = min(maxIndex, mentionIndex + 1)
      return .handled
    }

    if keyPress.modifiers.contains(.control) {
      if keyPress.key == KeyEquivalent("n") {
        mentionIndex = min(maxIndex, mentionIndex + 1)
        return .handled
      } else if keyPress.key == KeyEquivalent("p") {
        mentionIndex = max(0, mentionIndex - 1)
        return .handled
      }
    }

    if keyPress.key == .return || keyPress.key == .tab {
      if mentionIndex < filteredFiles.count {
        acceptMentionCompletion(filteredFiles[mentionIndex])
      }
      return .handled
    }

    return .ignored
  }

  // MARK: - Image Input

  private func pickImages() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.message = "Select images to attach"

    guard panel.runModal() == .OK else { return }

    for url in panel.urls {
      guard let nsImage = NSImage(contentsOf: url) else { continue }
      let thumbnail = createThumbnail(from: nsImage)
      let input = ServerImageInput(inputType: "path", value: url.path)
      let attached = AttachedImage(id: UUID().uuidString, thumbnail: thumbnail, serverInput: input)
      withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
        attachedImages.append(attached)
      }
    }
  }

  private func pasteImageFromClipboard() -> Bool {
    let pasteboard = NSPasteboard.general

    guard let imageType = pasteboard.availableType(from: [.tiff, .png]) else {
      return false
    }

    guard let data = pasteboard.data(forType: imageType),
          let nsImage = NSImage(data: data)
    else {
      return false
    }

    guard let tiffData = nsImage.tiffRepresentation,
          let bitmapRep = NSBitmapImageRep(data: tiffData),
          let pngData = bitmapRep.representation(using: .png, properties: [:])
    else {
      return false
    }

    let base64 = pngData.base64EncodedString()
    let dataURI = "data:image/png;base64,\(base64)"
    let thumbnail = createThumbnail(from: nsImage)
    let input = ServerImageInput(inputType: "url", value: dataURI)
    let attached = AttachedImage(id: UUID().uuidString, thumbnail: thumbnail, serverInput: input)

    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
      attachedImages.append(attached)
    }
    return true
  }

  private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
    var handled = false

    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
          guard let urlData = data as? Data,
                let url = URL(dataRepresentation: urlData, relativeTo: nil),
                let nsImage = NSImage(contentsOf: url)
          else { return }

          let thumbnail = createThumbnail(from: nsImage)
          let input = ServerImageInput(inputType: "path", value: url.path)
          let attached = AttachedImage(id: UUID().uuidString, thumbnail: thumbnail, serverInput: input)

          DispatchQueue.main.async {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
              attachedImages.append(attached)
            }
          }
        }
        handled = true
      } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { data, _ in
          guard let imageData = data as? Data,
                let nsImage = NSImage(data: imageData),
                let tiffData = nsImage.tiffRepresentation,
                let bitmapRep = NSBitmapImageRep(data: tiffData),
                let pngData = bitmapRep.representation(using: .png, properties: [:])
          else { return }

          let base64 = pngData.base64EncodedString()
          let dataURI = "data:image/png;base64,\(base64)"
          let thumbnail = createThumbnail(from: nsImage)
          let input = ServerImageInput(inputType: "url", value: dataURI)
          let attached = AttachedImage(id: UUID().uuidString, thumbnail: thumbnail, serverInput: input)

          DispatchQueue.main.async {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
              attachedImages.append(attached)
            }
          }
        }
        handled = true
      }
    }

    return handled
  }

  private func createThumbnail(from image: NSImage) -> NSImage {
    let size = NSSize(width: 80, height: 80)
    let thumbnail = NSImage(size: size)
    thumbnail.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
      in: NSRect(origin: .zero, size: size),
      from: NSRect(origin: .zero, size: image.size),
      operation: .copy,
      fraction: 1.0
    )
    thumbnail.unlockFocus()
    return thumbnail
  }
}

// MARK: - Interrupt Button

struct CodexInterruptButton: View {
  let sessionId: String
  @Environment(ServerAppState.self) private var serverState

  @State private var isInterrupting = false
  @State private var isHovering = false

  var body: some View {
    Button(action: interrupt) {
      HStack(spacing: 5) {
        if isInterrupting {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: "stop.fill")
            .font(.system(size: TypeScale.body, weight: .bold))
        }
        Text("Stop")
          .font(.system(size: TypeScale.body, weight: .semibold))
      }
      .foregroundStyle(Color.statusError)
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, 5)
      .background(Color.statusError.opacity(isHovering ? OpacityTier.medium : OpacityTier.light), in: Capsule())
      .shadow(color: Color.statusError.opacity(isHovering ? 0.3 : 0), radius: 6, y: 0)
    }
    .buttonStyle(.plain)
    .disabled(isInterrupting)
    .onHover { isHovering = $0 }
    .animation(.easeOut(duration: 0.15), value: isHovering)
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
  @Previewable @State var pinned = true
  @Previewable @State var unread = 0
  @Previewable @State var scroll = 0
  @Previewable @State var approvals = false
  InstrumentPanel(
    session: Session(
      id: "test-session",
      projectPath: "/Users/test/project",
      model: "o3",
      status: .active,
      workStatus: .working
    ),
    selectedSkills: $skills,
    isPinned: $pinned,
    unreadCount: $unread,
    scrollToBottomTrigger: $scroll,
    showApprovalHistory: $approvals
  )
  .environment(ServerAppState())
  .frame(width: 600)
}
