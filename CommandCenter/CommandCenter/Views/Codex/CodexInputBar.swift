//
//  CodexInputBar.swift
//  OrbitDock
//
//  Message input UI for direct Codex sessions.
//  Allows users to send prompts directly from OrbitDock.
//

import SwiftUI
import UniformTypeIdentifiers

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

  // Attachments
  @State private var fileIndex = ProjectFileIndex()
  @State private var attachedImages: [AttachedImage] = []
  @State private var attachedMentions: [AttachedMention] = []
  @State private var mentionActive = false
  @State private var mentionQuery = ""
  @State private var mentionIndex = 0

  // Input mode
  @State private var manualReviewMode = false

  private var inputMode: InputMode {
    if manualReviewMode { return .reviewNotes }
    if isSessionWorking { return .steer }
    return .prompt
  }

  private var isSessionWorking: Bool {
    serverState.sessions.first(where: { $0.id == sessionId })?.workStatus == .working
  }

  private var isSessionActive: Bool {
    serverState.sessions.first(where: { $0.id == sessionId })?.isActive ?? false
  }

  private var hasOverrides: Bool {
    selectedEffort != .default
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

  private var projectPath: String? {
    serverState.sessions.first(where: { $0.id == sessionId })?.projectPath
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

  var body: some View {
    VStack(spacing: 0) {
      Divider()

      // Input mode indicator
      if isSessionActive {
        SteerContextIndicator(mode: inputMode) {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            manualReviewMode.toggle()
          }
        }
      }

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

      // @ mention completion
      if shouldShowMentionCompletion, !isSessionWorking {
        MentionCompletionList(
          files: filteredFiles,
          selectedIndex: mentionIndex,
          query: mentionQuery,
          onSelect: acceptMentionCompletion
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      // Attachment bar
      if hasAttachments {
        AttachmentBar(images: $attachedImages, mentions: $attachedMentions)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      HStack(spacing: Spacing.md) {
        if !isSessionWorking {
          // Config toggle
          Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
              showConfig.toggle()
            }
          } label: {
            Image(systemName: "slider.horizontal.3")
              .font(.system(size: TypeScale.title))
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
              .font(.system(size: TypeScale.title))
              .foregroundStyle(!selectedSkills.isEmpty || hasInlineSkills ? Color.accent : .secondary)
          }
          .buttonStyle(.plain)
          .help("Attach skills")

          // Attach images
          Button { pickImages() } label: {
            Image(systemName: "paperclip")
              .font(.system(size: TypeScale.title))
              .foregroundStyle(!attachedImages.isEmpty ? Color.accent : .secondary)
          }
          .buttonStyle(.plain)
          .help("Attach images")
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
              updateMentionCompletion(newValue)
            }
          }
          .onKeyPress(phases: .down) { keyPress in
            // Check for paste (Cmd+V) with image on clipboard
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
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.md)

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
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.sm)
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

    let effort = selectedEffort == .default ? nil : selectedEffort.rawValue

    // Expand @filename mentions to absolute paths for the model
    var expandedContent = trimmed
    for mention in attachedMentions {
      expandedContent = expandedContent.replacingOccurrences(of: "@\(mention.name)", with: mention.path)
    }

    // Extract inline $skill-name references from message
    let inlineSkillNames = extractInlineSkillNames(from: expandedContent)

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

    // Build image inputs (mentions are already in the message text as paths)
    let imageInputs = attachedImages.map { $0.serverInput }

    // Send with attachments (expanded content has absolute paths)
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

  // MARK: - @ Mention Completion

  private func updateMentionCompletion(_ text: String) {
    guard let atIdx = text.lastIndex(of: "@") else {
      mentionActive = false
      return
    }

    // Only trigger if @ is at start or preceded by whitespace
    if atIdx != text.startIndex {
      let before = text[text.index(before: atIdx)]
      if !before.isWhitespace {
        mentionActive = false
        return
      }
    }

    let afterAt = text[text.index(after: atIdx)...]

    // Dismiss if there's whitespace after the last @
    if afterAt.contains(where: { $0.isWhitespace }) {
      mentionActive = false
      return
    }

    let query = String(afterAt)

    // Don't re-trigger when the query matches an attached mention's name or path (already accepted)
    if attachedMentions.contains(where: { $0.name == query || $0.path.hasSuffix(query) }) {
      mentionActive = false
      return
    }

    mentionQuery = query
    mentionIndex = 0
    mentionActive = true

    // Ensure file index is loaded
    if let path = projectPath {
      Task { await fileIndex.loadIfNeeded(path) }
    }
  }

  private func acceptMentionCompletion(_ file: ProjectFileIndex.ProjectFile) {
    // Replace @query with @filename (friendly display in input box)
    if let atIdx = message.lastIndex(of: "@") {
      let prefix = String(message[..<atIdx])
      message = prefix + "@" + file.name + " "
    }
    mentionActive = false
    mentionQuery = ""
    mentionIndex = 0
    isFocused = true

    // Store with absolute path — expanded at send time
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

    // Mention completion takes priority when active
    if shouldShowMentionCompletion {
      return handleMentionKeyPress(keyPress)
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

    // Check for image data on clipboard
    guard let imageType = pasteboard.availableType(from: [.tiff, .png]) else {
      return false
    }

    guard let data = pasteboard.data(forType: imageType),
          let nsImage = NSImage(data: data)
    else {
      return false
    }

    // Convert to PNG for base64 encoding
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
      // File URLs (images)
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
      }
      // Raw image data
      else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
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
    let size = NSSize(width: 80, height: 80) // 2x for retina
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
