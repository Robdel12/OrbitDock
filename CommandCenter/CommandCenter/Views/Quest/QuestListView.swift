//
//  QuestListView.swift
//  OrbitDock
//
//  List of all quests, grouped by status
//

import SwiftUI

struct QuestListView: View {
  let onSelectSession: (String) -> Void
  var initialQuestId: String?

  @Environment(SessionStore.self) private var db
  @State private var selectedQuest: Quest?
  @State private var showingCreateSheet = false
  @State private var showingDetailSheet = false
  @State private var didHandleInitialQuest = false

  private var activeQuests: [Quest] {
    db.allQuests.filter { $0.status == .active }
  }

  private var pausedQuests: [Quest] {
    db.allQuests.filter { $0.status == .paused }
  }

  private var completedQuests: [Quest] {
    db.allQuests.filter { $0.status == .completed }
  }

  var body: some View {
    ZStack {
      // Main content
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          // Header with create button
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text("Quests")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.primary)

              Text("Organize your work into flexible containers")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
              showingCreateSheet = true
            } label: {
              HStack(spacing: 6) {
                Image(systemName: "plus")
                  .font(.system(size: 11, weight: .semibold))
                Text("New Quest")
                  .font(.system(size: 12, weight: .semibold))
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .background(Color.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
              .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
          }

          // Active quests
          if !activeQuests.isEmpty {
            QuestSection(
              title: "Active",
              icon: "bolt.fill",
              color: .accent,
              quests: activeQuests,
              onSelectQuest: { quest in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                  selectedQuest = quest
                  showingDetailSheet = true
                }
              }
            )
          }

          // Paused quests
          if !pausedQuests.isEmpty {
            QuestSection(
              title: "Paused",
              icon: "pause.fill",
              color: .statusReply,
              quests: pausedQuests,
              onSelectQuest: { quest in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                  selectedQuest = quest
                  showingDetailSheet = true
                }
              }
            )
          }

          // Completed quests
          if !completedQuests.isEmpty {
            QuestSection(
              title: "Completed",
              icon: "checkmark.circle.fill",
              color: .statusEnded,
              quests: completedQuests,
              onSelectQuest: { quest in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                  selectedQuest = quest
                  showingDetailSheet = true
                }
              },
              isCollapsible: true
            )
          }

          // Empty state
          if db.allQuests.isEmpty {
            emptyState
          }
        }
        .padding(24)
      }
      .scrollContentBackground(.hidden)
      .background(Color.backgroundPrimary)

      // Quest detail overlay
      if showingDetailSheet, let quest = selectedQuest {
        questDetailOverlay(quest: quest)
      }
    }
    .onAppear {
      // Handle initial quest navigation
      if let questId = initialQuestId, !didHandleInitialQuest {
        didHandleInitialQuest = true
        if let quest = db.allQuests.first(where: { $0.id == questId }) {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            selectedQuest = quest
            showingDetailSheet = true
          }
        }
      }
    }
    .onChange(of: db.allQuests) { _, newQuests in
      // Handle initial quest if quests just loaded
      if let questId = initialQuestId, !didHandleInitialQuest {
        didHandleInitialQuest = true
        if let quest = newQuests.first(where: { $0.id == questId }) {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            selectedQuest = quest
            showingDetailSheet = true
          }
        }
      }
    }
    .sheet(isPresented: $showingCreateSheet) {
      CreateQuestSheet(onCreated: { quest in
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
          selectedQuest = quest
          showingDetailSheet = true
        }
      })
    }
  }

  // MARK: - Quest Detail Overlay

  private func questDetailOverlay(quest: Quest) -> some View {
    ZStack {
      // Backdrop
      Color.black.opacity(0.5)
        .ignoresSafeArea()
        .onTapGesture {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            showingDetailSheet = false
          }
        }

      // Detail view
      QuestDetailView(
        questId: quest.id,
        onSelectSession: { sessionId in
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            showingDetailSheet = false
          }
          onSelectSession(sessionId)
        },
        onDismiss: {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            showingDetailSheet = false
          }
        }
      )
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .shadow(color: .black.opacity(0.5), radius: 40, x: 0, y: 20)
    }
    .transition(.opacity)
    .onKeyPress(keys: [.escape]) { _ in
      withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
        showingDetailSheet = false
      }
      return .handled
    }
  }

  private var emptyState: some View {
    VStack(spacing: 20) {
      ZStack {
        Circle()
          .fill(Color.backgroundTertiary)
          .frame(width: 80, height: 80)
        Image(systemName: "scope")
          .font(.system(size: 32, weight: .light))
          .foregroundStyle(.tertiary)
      }

      VStack(spacing: 8) {
        Text("No Quests Yet")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.primary)

        Text("Create a quest to start organizing your work")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
      }

      Button {
        showingCreateSheet = true
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "plus")
            .font(.system(size: 11, weight: .semibold))
          Text("Create Your First Quest")
            .font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .foregroundStyle(.white)
      }
      .buttonStyle(.plain)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 60)
  }
}

// MARK: - Quest Section

struct QuestSection: View {
  let title: String
  let icon: String
  let color: Color
  let quests: [Quest]
  let onSelectQuest: (Quest) -> Void
  var isCollapsible: Bool = false

  @State private var isExpanded = true

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Section header
      Button {
        if isCollapsible {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            isExpanded.toggle()
          }
        }
      } label: {
        HStack(spacing: 8) {
          if isCollapsible {
            Image(systemName: "chevron.right")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.tertiary)
              .rotationEffect(.degrees(isExpanded ? 90 : 0))
          }

          Image(systemName: icon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)

          Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)

          Text("\(quests.count)")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)

          Spacer()
        }
      }
      .buttonStyle(.plain)
      .disabled(!isCollapsible)

      // Quest rows
      if isExpanded {
        VStack(spacing: 8) {
          ForEach(quests) { quest in
            QuestRow(quest: quest) {
              onSelectQuest(quest)
            }
          }
        }
      }
    }
  }
}

// MARK: - Create Quest Sheet

struct CreateQuestSheet: View {
  let onCreated: (Quest) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var description = ""

  private let db = SessionStore.shared

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text("New Quest")
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
        VStack(alignment: .leading, spacing: 8) {
          Text("Name")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)

          TextField("Quest name", text: $name)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .padding(12)
            .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }

        VStack(alignment: .leading, spacing: 8) {
          Text("Description (optional)")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)

          TextField("What is this quest about?", text: $description, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .lineLimit(3 ... 6)
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
          createQuest()
        } label: {
          Text("Create Quest")
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      .padding(20)
    }
    .frame(width: 400, height: 350)
    .background(Color.backgroundSecondary)
  }

  private func createQuest() {
    let trimmedName = name.trimmingCharacters(in: .whitespaces)
    let trimmedDesc = description.trimmingCharacters(in: .whitespaces)

    Task {
      if let quest = await db.createQuest(
        name: trimmedName,
        description: trimmedDesc.isEmpty ? nil : trimmedDesc,
        color: nil
      ) {
        onCreated(quest)
        dismiss()
      }
    }
  }
}

#Preview {
  QuestListView(onSelectSession: { _ in })
    .environment(SessionStore.shared)
    .frame(width: 800, height: 600)
}
