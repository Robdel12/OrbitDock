//
//  InboxView.swift
//  OrbitDock
//
//  Global inbox for quick capture - ideas float free until organized
//

import SwiftUI

struct InboxView: View {
  var onClose: (() -> Void)? = nil

  @Environment(DatabaseManager.self) private var db
  @State private var newItemText = ""
  @State private var showingAttachSheet = false
  @State private var showingEditSheet = false
  @State private var selectedItem: InboxItem?
  @State private var selectedIndex: Int = 0
  @FocusState private var isInputFocused: Bool
  @FocusState private var isListFocused: Bool

  private var pendingItems: [InboxItem] {
    db.allInboxItems.filter { $0.status == .pending }
  }

  private var processedItems: [InboxItem] {
    db.allInboxItems.filter { $0.status.isProcessed }
  }

  private var activeQuests: [Quest] {
    db.allQuests.filter { $0.status != .completed }
  }

  var body: some View {
    VStack(spacing: 0) {
      // Header with close button
      if onClose != nil {
        inboxHeader
        Divider()
          .foregroundStyle(Color.panelBorder)
      }

      // Quick capture input
      captureInput

      Divider()
        .foregroundStyle(Color.panelBorder)

      // Items list
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            // Pending items
            if !pendingItems.isEmpty {
              VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                  Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                  Text("Inbox")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                  Text("\(pendingItems.count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                }

                VStack(spacing: 6) {
                  ForEach(Array(pendingItems.enumerated()), id: \.element.id) { index, item in
                    InboxItemCard(
                      item: item,
                      isSelected: index == selectedIndex && !isInputFocused,
                      onEdit: {
                        selectedItem = item
                        showingEditSheet = true
                      },
                      onAttach: {
                        selectedItem = item
                        showingAttachSheet = true
                      },
                      onLinear: {
                        // Open Linear with pre-filled content
                        let title = item.content.prefix(100)
                        let encodedTitle = String(title).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        if let url = URL(string: "https://linear.app/new?title=\(encodedTitle)") {
                          NSWorkspace.shared.open(url)
                          db.convertInboxItemToLinear(id: item.id, issueId: "", issueUrl: "")
                        }
                      },
                      onDone: {
                        db.markInboxItemDone(id: item.id)
                      },
                      onArchive: {
                        db.archiveInboxItem(id: item.id)
                      },
                      onDelete: {
                        db.deleteInboxItem(id: item.id)
                      }
                    )
                    .id("item-\(index)")
                    .onTapGesture {
                      selectedIndex = index
                      isInputFocused = false
                    }
                  }
                }
              }
            }

            // Processed items (collapsed)
            if !processedItems.isEmpty {
              ProcessedItemsSection(items: processedItems)
            }

            // Empty state
            if db.allInboxItems.isEmpty {
              emptyState
            }
          }
          .padding(20)
        }
        .scrollContentBackground(.hidden)
        .onChange(of: selectedIndex) { _, newIndex in
          withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("item-\(newIndex)", anchor: .center)
          }
        }
      }

      // Footer with keyboard hints
      if onClose != nil {
        inboxFooter
      }
    }
    .background(Color.backgroundPrimary)
    .focusable()
    .focused($isListFocused)
    .onKeyPress(keys: [.escape]) { _ in
      onClose?()
      return .handled
    }
    .onAppear {
      // Focus the input by default
      isInputFocused = true
    }
    .onChange(of: pendingItems.count) { oldCount, newCount in
      // Adjust selection if items were removed
      if selectedIndex >= newCount, newCount > 0 {
        selectedIndex = newCount - 1
      }
    }
    .modifier(InboxKeyboardModifier(
      isInputFocused: isInputFocused,
      onMoveUp: { moveSelection(by: -1) },
      onMoveDown: { moveSelection(by: 1) },
      onMoveToFirst: { selectedIndex = 0 },
      onMoveToLast: {
        if !pendingItems.isEmpty {
          selectedIndex = pendingItems.count - 1
        }
      },
      onAttach: { attachSelectedItem() },
      onDelete: { deleteSelectedItem() },
      onFocusInput: {
        isInputFocused = true
      },
      onUnfocusInput: {
        isInputFocused = false
      }
    ))
    .sheet(isPresented: $showingAttachSheet) {
      if let item = selectedItem {
        AttachToQuestSheet(item: item, quests: activeQuests)
      }
    }
    .sheet(isPresented: $showingEditSheet) {
      if let item = selectedItem {
        EditInboxItemSheet(item: item)
      }
    }
  }

  // MARK: - Keyboard Navigation

  private func moveSelection(by delta: Int) {
    guard !pendingItems.isEmpty else { return }

    // If input is focused and moving down, go to first item
    if isInputFocused && delta > 0 {
      isInputFocused = false
      selectedIndex = 0
      return
    }

    // If at first item and moving up, go to input
    if selectedIndex == 0 && delta < 0 && !isInputFocused {
      isInputFocused = true
      return
    }

    // Unfocus input when navigating
    isInputFocused = false

    let newIndex = selectedIndex + delta
    if newIndex < 0 {
      // Already handled above for going to input
      selectedIndex = pendingItems.count - 1
    } else if newIndex >= pendingItems.count {
      selectedIndex = 0
    } else {
      selectedIndex = newIndex
    }
  }

  private func attachSelectedItem() {
    guard selectedIndex < pendingItems.count else { return }
    selectedItem = pendingItems[selectedIndex]
    showingAttachSheet = true
  }

  private func deleteSelectedItem() {
    guard selectedIndex < pendingItems.count else { return }
    let item = pendingItems[selectedIndex]
    db.deleteInboxItem(id: item.id)
  }

  // MARK: - Header

  private var inboxHeader: some View {
    HStack {
      HStack(spacing: 8) {
        Image(systemName: "tray.and.arrow.down")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Color.accent)
        Text("Inbox")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.primary)
      }

      Spacer()

      Button {
        onClose?()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 28, height: 28)
          .background(Color.backgroundTertiary, in: Circle())
      }
      .buttonStyle(.plain)
    }
    .padding(16)
  }

  private var inboxFooter: some View {
    HStack(spacing: 0) {
      footerHint(keys: "C-n/p", label: "Navigate")
      footerDivider
      footerHint(keys: "↵", label: "Attach")
      footerDivider
      footerHint(keys: "C-d", label: "Delete")
      footerDivider
      footerHint(keys: "Tab", label: "Input")

      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(Color.backgroundTertiary.opacity(0.3))
  }

  private var footerDivider: some View {
    Rectangle()
      .fill(Color.panelBorder)
      .frame(width: 1, height: 14)
      .padding(.horizontal, 10)
  }

  private func footerHint(keys: String, label: String) -> some View {
    HStack(spacing: 5) {
      Text(keys)
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

      Text(label)
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }
  }

  // MARK: - Capture Input

  private var captureInput: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "plus.circle.fill")
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(Color.accent)
        .padding(.top, 2)

      TextField("Capture a quick note...", text: $newItemText, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.system(size: 14))
        .lineLimit(1...5)
        .focused($isInputFocused)
        .onKeyPress(keys: [.return]) { keyPress in
          // Modifier+Enter = newline, plain Enter = submit
          if keyPress.modifiers.contains(.shift) ||
              keyPress.modifiers.contains(.option) ||
              keyPress.modifiers.contains(.control) {
            newItemText += "\n"
            return .handled
          } else {
            captureItem()
            return .handled
          }
        }

      if !newItemText.isEmpty {
        Button {
          captureItem()
        } label: {
          Text("Add")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(16)
    .background(Color.backgroundSecondary)
  }

  private var emptyState: some View {
    VStack(spacing: 16) {
      ZStack {
        Circle()
          .fill(Color.backgroundTertiary)
          .frame(width: 64, height: 64)
        Image(systemName: "tray")
          .font(.system(size: 28, weight: .light))
          .foregroundStyle(.tertiary)
      }

      VStack(spacing: 6) {
        Text("Inbox Empty")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.primary)

        Text("Capture quick ideas here.\nAttach them to quests when you're ready.")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      Button {
        isInputFocused = true
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "plus")
            .font(.system(size: 10, weight: .semibold))
          Text("Capture Something")
            .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(Color.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      .buttonStyle(.plain)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
  }

  // MARK: - Helpers

  private func captureItem() {
    let trimmed = newItemText.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }

    _ = db.captureToInbox(content: trimmed, source: .manual)
    newItemText = ""
  }
}

// MARK: - Inbox Item Card

struct InboxItemCard: View {
  let item: InboxItem
  var isSelected: Bool = false
  let onEdit: () -> Void
  let onAttach: () -> Void
  let onLinear: () -> Void
  let onDone: () -> Void
  let onArchive: () -> Void
  let onDelete: () -> Void

  @State private var isHovering = false

  private var showActions: Bool {
    isHovering || isSelected
  }

  var body: some View {
    HStack(spacing: 12) {
      // Selection indicator
      if isSelected {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .fill(Color.accent)
          .frame(width: 3, height: 24)
      } else {
        // Drag handle (visual only for now)
        Image(systemName: "line.3.horizontal")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.quaternary)
      }

      // Content
      VStack(alignment: .leading, spacing: 4) {
        Text(item.content)
          .font(.system(size: 13))
          .foregroundStyle(.primary)
          .lineLimit(3)

        HStack(spacing: 8) {
          // Source badge
          HStack(spacing: 4) {
            Image(systemName: item.source.icon)
              .font(.system(size: 9))
            Text(item.source.label)
              .font(.system(size: 10, weight: .medium))
          }
          .foregroundStyle(.tertiary)

          // Time
          Text(item.createdAt, style: .relative)
            .font(.system(size: 10))
            .foregroundStyle(.quaternary)
        }
      }

      Spacer()

      // Actions (on hover or selected)
      if showActions {
        HStack(spacing: 6) {
          // Quick "Done" action
          Button {
            onDone()
          } label: {
            Label("Done", systemImage: "checkmark")
              .font(.system(size: 11, weight: .medium))
              .labelStyle(.titleAndIcon)
              .foregroundStyle(.green)
              .padding(.horizontal, 8)
              .padding(.vertical, 5)
              .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          }
          .buttonStyle(.plain)

          // More actions menu
          Menu {
            Button { onEdit() } label: {
              Label("Edit", systemImage: "pencil")
            }

            Divider()

            Button { onAttach() } label: {
              Label("Attach to Quest", systemImage: "scope")
            }

            Button { onLinear() } label: {
              Label("Create Linear Issue", systemImage: "link")
            }

            Divider()

            Button { onArchive() } label: {
              Label("Archive", systemImage: "archivebox")
            }

            Button(role: .destructive) { onDelete() } label: {
              Label("Delete", systemImage: "trash")
            }
          } label: {
            Image(systemName: "ellipsis")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(.secondary)
              .frame(width: 24, height: 24)
              .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
        }
        .fixedSize(horizontal: true, vertical: true)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(backgroundColor)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(isSelected ? Color.accent.opacity(0.5) : Color.surfaceBorder.opacity(0.3), lineWidth: 1)
    )
    .onHover { isHovering = $0 }
    .animation(.easeOut(duration: 0.15), value: showActions)
  }

  private var backgroundColor: Color {
    if isSelected {
      Color.accent.opacity(0.1)
    } else if isHovering {
      Color.surfaceHover
    } else {
      Color.backgroundTertiary.opacity(0.5)
    }
  }
}

// MARK: - Processed Items Section

struct ProcessedItemsSection: View {
  let items: [InboxItem]

  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))

          Image(systemName: "tray.full")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.tertiary)

          Text("Processed")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.tertiary)

          Text("\(items.count)")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.quaternary)

          Spacer()
        }
      }
      .buttonStyle(.plain)

      if isExpanded {
        VStack(spacing: 4) {
          ForEach(items) { item in
            HStack(spacing: 10) {
              // Status icon
              Image(systemName: item.status.icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(statusColor(for: item.status))
                .frame(width: 16)

              Text(item.content)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

              Spacer()

              // Status label
              Text(item.status.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(statusColor(for: item.status).opacity(0.8))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(statusColor(for: item.status).opacity(0.1), in: Capsule())

              // Linear link if converted
              if let url = item.linearIssueUrl {
                Button {
                  if let linkUrl = URL(string: url) {
                    NSWorkspace.shared.open(linkUrl)
                  }
                } label: {
                  Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open in Linear")
              }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
          }
        }
      }
    }
  }

  private func statusColor(for status: InboxItem.Status) -> Color {
    switch status {
    case .pending: .secondary
    case .attached: .accent
    case .converted: .purple
    case .completed: .green
    case .archived: .orange
    }
  }
}

// MARK: - Attach to Quest Sheet

struct AttachToQuestSheet: View {
  let item: InboxItem
  let quests: [Quest]

  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""

  private let db = DatabaseManager.shared

  private var filteredQuests: [Quest] {
    if searchText.isEmpty {
      return quests
    }
    return quests.filter { quest in
      quest.name.localizedCaseInsensitiveContains(searchText)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      // Header
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Attach to Quest")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)

          Spacer()

          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(.secondary)
              .frame(width: 28, height: 28)
              .background(Color.backgroundTertiary, in: Circle())
          }
          .buttonStyle(.plain)
        }

        Text(item.preview)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .padding(20)

      Divider()
        .foregroundStyle(Color.panelBorder)

      // Search
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 12))
          .foregroundStyle(.tertiary)

        TextField("Search quests...", text: $searchText)
          .textFieldStyle(.plain)
          .font(.system(size: 14))
      }
      .padding(12)
      .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .padding(20)

      // Quest list
      ScrollView {
        LazyVStack(spacing: 6) {
          ForEach(filteredQuests) { quest in
            Button {
              db.attachInboxItem(id: item.id, toQuest: quest.id)
              dismiss()
            } label: {
              HStack(spacing: 12) {
                Circle()
                  .fill(quest.isActive ? Color.accent : Color.statusReply)
                  .frame(width: 8, height: 8)

                Text(quest.name)
                  .font(.system(size: 13, weight: .medium))
                  .foregroundStyle(.primary)
                  .lineLimit(1)

                Spacer()

                Text(quest.status.label)
                  .font(.system(size: 10, weight: .medium))
                  .foregroundStyle(.tertiary)
              }
              .padding(.vertical, 10)
              .padding(.horizontal, 12)
              .background(Color.backgroundTertiary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
      }
    }
    .frame(width: 400, height: 450)
    .background(Color.backgroundSecondary)
  }
}

// MARK: - Edit Inbox Item Sheet

struct EditInboxItemSheet: View {
  let item: InboxItem

  @Environment(\.dismiss) private var dismiss
  @State private var content: String = ""

  private let db = DatabaseManager.shared

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text("Edit Item")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.primary)

        Spacer()

        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(Color.backgroundTertiary, in: Circle())
        }
        .buttonStyle(.plain)
      }
      .padding(20)

      Divider()
        .foregroundStyle(Color.panelBorder)

      // Content editor
      VStack(alignment: .leading, spacing: 8) {
        Text("Content")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)

        TextEditor(text: $content)
          .font(.system(size: 14))
          .scrollContentBackground(.hidden)
          .padding(12)
          .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          .frame(minHeight: 120)
      }
      .padding(20)

      Spacer()

      Divider()
        .foregroundStyle(Color.panelBorder)

      // Actions
      HStack {
        Spacer()

        Button("Cancel") {
          dismiss()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)

        Button {
          saveChanges()
        } label: {
          Text("Save")
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding(20)
    }
    .frame(width: 450, height: 350)
    .background(Color.backgroundSecondary)
    .onAppear {
      content = item.content
    }
  }

  private func saveChanges() {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    db.updateInboxItem(id: item.id, content: trimmed)
    dismiss()
  }
}

// MARK: - Keyboard Navigation Modifier

struct InboxKeyboardModifier: ViewModifier {
  let isInputFocused: Bool
  let onMoveUp: () -> Void
  let onMoveDown: () -> Void
  let onMoveToFirst: () -> Void
  let onMoveToLast: () -> Void
  let onAttach: () -> Void
  let onDelete: () -> Void
  let onFocusInput: () -> Void
  let onUnfocusInput: () -> Void

  func body(content: Content) -> some View {
    content
      // Arrow keys (only when not typing)
      .onKeyPress(keys: [.upArrow]) { _ in
        guard !isInputFocused else { return .ignored }
        onMoveUp()
        return .handled
      }
      .onKeyPress(keys: [.downArrow]) { _ in
        guard !isInputFocused else { return .ignored }
        onMoveDown()
        return .handled
      }
      // Enter to attach (only when not typing)
      .onKeyPress(keys: [.return]) { _ in
        guard !isInputFocused else { return .ignored }
        onAttach()
        return .handled
      }
      // Delete/Backspace to delete (only when not typing)
      .onKeyPress(keys: [.delete]) { _ in
        guard !isInputFocused else { return .ignored }
        onDelete()
        return .handled
      }
      // Tab to focus input
      .onKeyPress(keys: [.tab]) { _ in
        onFocusInput()
        return .handled
      }
      // Handle Emacs bindings
      .onKeyPress { keyPress in
        // C-p (previous) - works even when input focused (exits input)
        if keyPress.key == "p", keyPress.modifiers.contains(.control) {
          if isInputFocused { onUnfocusInput() }
          onMoveUp()
          return .handled
        }
        // C-n (next) - works even when input focused (exits input)
        if keyPress.key == "n", keyPress.modifiers.contains(.control) {
          if isInputFocused { onUnfocusInput() }
          onMoveDown()
          return .handled
        }

        // Rest only work when not typing
        guard !isInputFocused else { return .ignored }

        // C-a (first)
        if keyPress.key == "a", keyPress.modifiers.contains(.control) {
          onMoveToFirst()
          return .handled
        }
        // C-e (last)
        if keyPress.key == "e", keyPress.modifiers.contains(.control) {
          onMoveToLast()
          return .handled
        }
        // C-d (delete)
        if keyPress.key == "d", keyPress.modifiers.contains(.control) {
          onDelete()
          return .handled
        }
        // C-o (focus input)
        if keyPress.key == "o", keyPress.modifiers.contains(.control) {
          onFocusInput()
          return .handled
        }
        return .ignored
      }
  }
}

#Preview {
  InboxView(onClose: {})
    .environment(DatabaseManager.shared)
    .frame(width: 500, height: 600)
}
