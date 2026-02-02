//
//  QuestDetailView.swift
//  OrbitDock
//
//  Detailed view of a quest with linked sessions, links, and inbox items
//

import SwiftUI

struct QuestDetailView: View {
  let questId: String
  let onSelectSession: (String) -> Void
  let onDismiss: () -> Void

  @Environment(DatabaseManager.self) private var db
  @State private var quest: Quest?
  @State private var showingAddLink = false
  @State private var showingLinkSession = false
  @State private var isEditingName = false
  @State private var editedName = ""

  var body: some View {
    VStack(spacing: 0) {
      if let quest {
        // Header
        questHeader(quest)

        Divider()
          .foregroundStyle(Color.panelBorder)

        // Content
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            // Description
            if let description = quest.description, !description.isEmpty {
              VStack(alignment: .leading, spacing: 8) {
                Text("Description")
                  .font(.system(size: 12, weight: .semibold))
                  .foregroundStyle(.secondary)

                Text(description)
                  .font(.system(size: 14))
                  .foregroundStyle(.primary)
              }
            }

            // Linked Sessions
            sessionsSection(quest)

            // Links (PRs, Issues, etc.)
            linksSection(quest)

            // Attached Inbox Items
            inboxSection(quest)
          }
          .padding(24)
        }
        .scrollContentBackground(.hidden)
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(width: 600, height: 700)
    .background(Color.backgroundSecondary)
    .onAppear { loadQuest() }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DatabaseChanged"))) { _ in
      loadQuest()
    }
    .sheet(isPresented: $showingAddLink) {
      AddLinkSheet(questId: questId)
    }
    .sheet(isPresented: $showingLinkSession) {
      LinkSessionSheet(questId: questId)
    }
  }

  // MARK: - Header

  private func questHeader(_ quest: Quest) -> some View {
    HStack(spacing: 12) {
      // Status indicator
      Circle()
        .fill(statusColor(for: quest))
        .frame(width: 10, height: 10)

      // Name (editable)
      if isEditingName {
        TextField("Quest name", text: $editedName)
          .textFieldStyle(.plain)
          .font(.system(size: 18, weight: .semibold))
          .onSubmit { saveName() }
          .onExitCommand { cancelEditName() }
      } else {
        Text(quest.name)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(.primary)
          .onTapGesture(count: 2) {
            editedName = quest.name
            isEditingName = true
          }
      }

      Spacer()

      // Status toggle
      statusMenu(quest)

      // Close button
      Button {
        onDismiss()
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
  }

  private func statusMenu(_ quest: Quest) -> some View {
    Menu {
      ForEach(Quest.Status.allCases, id: \.self) { status in
        Button {
          db.updateQuest(id: questId, status: status)
        } label: {
          HStack {
            Image(systemName: status.icon)
            Text(status.label)
            if quest.status == status {
              Spacer()
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: quest.status.icon)
          .font(.system(size: 10, weight: .medium))
        Text(quest.status.label)
          .font(.system(size: 12, weight: .semibold))
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .bold))
      }
      .foregroundStyle(statusColor(for: quest))
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(statusColor(for: quest).opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .menuStyle(.borderlessButton)
  }

  // MARK: - Sessions Section

  private func sessionsSection(_ quest: Quest) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        HStack(spacing: 6) {
          Image(systemName: "cpu")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
          Text("Sessions")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
          Text("\(quest.sessions?.count ?? 0)")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
        }

        Spacer()

        Button {
          showingLinkSession = true
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "plus")
              .font(.system(size: 10, weight: .semibold))
            Text("Link Session")
              .font(.system(size: 11, weight: .medium))
          }
          .foregroundStyle(.secondary)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
      }

      if let sessions = quest.sessions, !sessions.isEmpty {
        VStack(spacing: 6) {
          ForEach(sessions) { session in
            QuestSessionRow(session: session) {
              onSelectSession(session.id)
            } onUnlink: {
              db.unlinkSessionFromQuest(sessionId: session.id, questId: questId)
            }
          }
        }
      } else {
        emptyPlaceholder(
          icon: "cpu",
          text: "No sessions linked yet",
          hint: "Link a session to track it as part of this quest"
        )
      }
    }
  }

  // MARK: - Links Section

  private func linksSection(_ quest: Quest) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        HStack(spacing: 6) {
          Image(systemName: "link")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
          Text("Links")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
          Text("\(quest.links?.count ?? 0)")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
        }

        Spacer()

        Button {
          showingAddLink = true
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "plus")
              .font(.system(size: 10, weight: .semibold))
            Text("Add Link")
              .font(.system(size: 11, weight: .medium))
          }
          .foregroundStyle(.secondary)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
      }

      if let links = quest.links, !links.isEmpty {
        VStack(spacing: 6) {
          ForEach(links) { link in
            QuestLinkRow(link: link) {
              db.removeQuestLink(id: link.id)
            }
          }
        }
      } else {
        emptyPlaceholder(
          icon: "link",
          text: "No links yet",
          hint: "Add PRs, issues, or other links"
        )
      }
    }
  }

  // MARK: - Inbox Section

  private func inboxSection(_ quest: Quest) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 6) {
        Image(systemName: "tray")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
        Text("Attached Notes")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.primary)
        Text("\(quest.inboxItems?.count ?? 0)")
          .font(.system(size: 11, weight: .medium, design: .rounded))
          .foregroundStyle(.tertiary)
      }

      if let items = quest.inboxItems, !items.isEmpty {
        VStack(spacing: 6) {
          ForEach(items) { item in
            InboxItemRow(item: item) {
              db.detachInboxItem(id: item.id)
            }
          }
        }
      } else {
        emptyPlaceholder(
          icon: "tray",
          text: "No notes attached",
          hint: "Capture ideas with the inbox and attach them here"
        )
      }
    }
  }

  // MARK: - Helpers

  private func emptyPlaceholder(icon: String, text: String, hint: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: icon)
        .font(.system(size: 24, weight: .light))
        .foregroundStyle(.quaternary)

      VStack(spacing: 4) {
        Text(text)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.tertiary)

        Text(hint)
          .font(.system(size: 11))
          .foregroundStyle(.quaternary)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
    .background(Color.backgroundTertiary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func statusColor(for quest: Quest) -> Color {
    switch quest.status {
    case .active: Color.accent
    case .paused: Color.statusReply
    case .completed: Color.statusEnded
    }
  }

  private func loadQuest() {
    quest = db.fetchQuest(id: questId)
  }

  private func saveName() {
    let trimmed = editedName.trimmingCharacters(in: .whitespaces)
    if !trimmed.isEmpty {
      db.updateQuest(id: questId, name: trimmed)
    }
    isEditingName = false
  }

  private func cancelEditName() {
    isEditingName = false
    editedName = quest?.name ?? ""
  }
}

// MARK: - Quest Session Row

struct QuestSessionRow: View {
  let session: Session
  let onSelect: () -> Void
  let onUnlink: () -> Void

  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 12) {
      // Status dot
      Circle()
        .fill(session.isActive ? Color.accent : Color.statusEnded)
        .frame(width: 6, height: 6)

      // Session name
      Text(session.displayName)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.primary)
        .lineLimit(1)

      Spacer()

      // Stats
      if session.toolCount > 0 {
        HStack(spacing: 4) {
          Image(systemName: "hammer")
            .font(.system(size: 9))
          Text("\(session.toolCount)")
            .font(.system(size: 10, weight: .medium, design: .rounded))
        }
        .foregroundStyle(.tertiary)
      }

      Text(session.formattedDuration)
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.tertiary)

      // Unlink button (on hover)
      if isHovering {
        Button {
          onUnlink()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.tertiary)
            .frame(width: 20, height: 20)
            .background(Color.backgroundTertiary, in: Circle())
        }
        .buttonStyle(.plain)
        .help("Unlink session")
      }
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(isHovering ? Color.surfaceHover : Color.backgroundTertiary.opacity(0.5))
    )
    .onTapGesture { onSelect() }
    .onHover { isHovering = $0 }
  }
}

// MARK: - Quest Link Row

struct QuestLinkRow: View {
  let link: QuestLink
  let onRemove: () -> Void

  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 10) {
      // Source icon
      Image(systemName: link.source.icon)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(sourceColor)

      // Link info
      VStack(alignment: .leading, spacing: 2) {
        Text(link.displayName)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.primary)
          .lineLimit(1)

        HStack(spacing: 6) {
          Text(link.source.shortLabel)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(sourceColor)

          if link.detectedFrom == .cliOutput {
            Text("Auto-detected")
              .font(.system(size: 10))
              .foregroundStyle(.tertiary)
          }
        }
      }

      Spacer()

      // Open link
      Button {
        if let url = URL(string: link.url) {
          NSWorkspace.shared.open(url)
        }
      } label: {
        Image(systemName: "arrow.up.right")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Open in browser")

      // Remove button (on hover)
      if isHovering {
        Button {
          onRemove()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.tertiary)
            .frame(width: 20, height: 20)
            .background(Color.backgroundTertiary, in: Circle())
        }
        .buttonStyle(.plain)
        .help("Remove link")
      }
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(isHovering ? Color.surfaceHover : Color.backgroundTertiary.opacity(0.5))
    )
    .onHover { isHovering = $0 }
  }

  private var sourceColor: Color {
    switch link.source {
    case .githubPR: Color.green
    case .githubIssue: Color.green
    case .linear: Color.purple
    case .planFile: Color.orange
    }
  }
}

// MARK: - Inbox Item Row

struct InboxItemRow: View {
  let item: InboxItem
  let onDetach: () -> Void

  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: item.source.icon)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.tertiary)

      Text(item.content)
        .font(.system(size: 13))
        .foregroundStyle(.primary)
        .lineLimit(2)

      Spacer()

      // Detach button (on hover)
      if isHovering {
        Button {
          onDetach()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.tertiary)
            .frame(width: 20, height: 20)
            .background(Color.backgroundTertiary, in: Circle())
        }
        .buttonStyle(.plain)
        .help("Detach from quest")
      }
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(isHovering ? Color.surfaceHover : Color.backgroundTertiary.opacity(0.5))
    )
    .onHover { isHovering = $0 }
  }
}

// MARK: - Add Link Sheet

struct AddLinkSheet: View {
  let questId: String

  @Environment(\.dismiss) private var dismiss
  @State private var url = ""
  @State private var title = ""
  @State private var selectedSource: QuestLink.Source = .githubPR

  private let db = DatabaseManager.shared

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text("Add Link")
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

      // Form
      VStack(alignment: .leading, spacing: 16) {
        // Source picker
        VStack(alignment: .leading, spacing: 8) {
          Text("Type")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)

          Picker("Type", selection: $selectedSource) {
            ForEach([QuestLink.Source.githubPR, .githubIssue, .linear, .planFile], id: \.self) { source in
              Text(source.label).tag(source)
            }
          }
          .pickerStyle(.segmented)
        }

        // URL
        VStack(alignment: .leading, spacing: 8) {
          Text("URL")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)

          TextField("https://...", text: $url)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .padding(12)
            .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }

        // Title (optional)
        VStack(alignment: .leading, spacing: 8) {
          Text("Title (optional)")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)

          TextField("Link title", text: $title)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .padding(12)
            .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
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
          addLink()
        } label: {
          Text("Add Link")
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      .padding(20)
    }
    .frame(width: 400, height: 380)
    .background(Color.backgroundSecondary)
  }

  private func addLink() {
    let trimmedUrl = url.trimmingCharacters(in: .whitespaces)
    let trimmedTitle = title.trimmingCharacters(in: .whitespaces)

    _ = db.addQuestLink(
      questId: questId,
      source: selectedSource,
      url: trimmedUrl,
      title: trimmedTitle.isEmpty ? nil : trimmedTitle,
      detectedFrom: .manual
    )

    dismiss()
  }
}

// MARK: - Link Session Sheet

struct LinkSessionSheet: View {
  let questId: String

  @Environment(\.dismiss) private var dismiss
  @State private var sessions: [Session] = []
  @State private var searchText = ""

  private let db = DatabaseManager.shared

  private var filteredSessions: [Session] {
    if searchText.isEmpty {
      return sessions
    }
    return sessions.filter { session in
      session.displayName.localizedCaseInsensitiveContains(searchText) ||
      session.projectPath.localizedCaseInsensitiveContains(searchText)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text("Link Session")
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

      // Search
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 12))
          .foregroundStyle(.tertiary)

        TextField("Search sessions...", text: $searchText)
          .textFieldStyle(.plain)
          .font(.system(size: 14))
      }
      .padding(12)
      .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .padding(20)

      // Session list
      ScrollView {
        LazyVStack(spacing: 6) {
          ForEach(filteredSessions) { session in
            Button {
              db.linkSessionToQuest(sessionId: session.id, questId: questId)
              dismiss()
            } label: {
              HStack(spacing: 12) {
                Circle()
                  .fill(session.isActive ? Color.accent : Color.statusEnded)
                  .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 2) {
                  Text(session.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                  Text(session.projectPath.components(separatedBy: "/").last ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                }

                Spacer()

                Text(session.formattedDuration)
                  .font(.system(size: 10, weight: .medium, design: .monospaced))
                  .foregroundStyle(.tertiary)
              }
              .padding(.vertical, 8)
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
    .frame(width: 450, height: 500)
    .background(Color.backgroundSecondary)
    .onAppear {
      sessions = db.fetchSessions()
    }
  }
}

#Preview {
  QuestDetailView(
    questId: "preview",
    onSelectSession: { _ in },
    onDismiss: {}
  )
}
