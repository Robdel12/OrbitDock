import SwiftUI

struct OrbitDockWindowRoot: View {
  @State private var appStore: AppStore
  @State private var selectedSessionRef: SessionRef?

  let connection: ServerConnection

  init(connection: ServerConnection) {
    self.connection = connection
    _appStore = State(initialValue: AppStore(connection: connection))
  }

  var body: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      detail
    }
    .preferredColorScheme(.dark)
    .background(Color.backgroundPrimary)
    .environment(appStore)
    .environment(connection)
    .task {
      appStore.start()
    }
  }

  // MARK: - Sidebar

  private var sidebar: some View {
    List(appStore.sessions, selection: $selectedSessionRef) { session in
      NavigationLink(value: session.sessionRef) {
        SessionSidebarRow(session: session)
      }
    }
    .navigationTitle("OrbitDock")
    #if os(macOS)
      .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 350)
    #endif
  }

  // MARK: - Detail

  @ViewBuilder
  private var detail: some View {
    if let ref = selectedSessionRef {
      SessionConversationView(
        sessionRef: ref,
        clients: connection.clients
      )
      .id(ref.scopedID)
    } else {
      ContentUnavailableView(
        "Select a Session",
        systemImage: "bubble.left.and.bubble.right",
        description: Text("Choose an agent session from the sidebar")
      )
    }
  }
}

// MARK: - Sidebar Row

struct SessionSidebarRow: View {
  let session: RootSessionNode

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Circle()
          .fill(statusColor)
          .frame(width: 8, height: 8)
        Text(session.title)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(Color.textPrimary)
      }

      if let contextLine = session.contextLine {
        Text(contextLine)
          .font(.system(size: 11))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(1)
      }

      HStack(spacing: 4) {
        if let projectName = session.projectName {
          Text(projectName)
            .font(.system(size: 10))
            .foregroundStyle(Color.textQuaternary)
        }
        if let model = session.model {
          Text("·")
            .foregroundStyle(Color.textQuaternary)
          Text(model)
            .font(.system(size: 10))
            .foregroundStyle(Color.textQuaternary)
        }
      }
    }
    .padding(.vertical, 2)
  }

  private var statusColor: Color {
    switch session.displayStatus {
    case .working: Color.statusWorking
    case .permission: Color.statusPermission
    case .question: Color.statusQuestion
    case .reply: Color.statusReply
    case .ended: Color.statusEnded
    }
  }
}

// MARK: - Session Conversation View (loads data from API)

struct SessionConversationView: View {
  let sessionRef: SessionRef
  let clients: ServerClients

  @State private var messages: [TranscriptMessage] = []
  @State private var sessionState: ServerSessionState?
  @State private var isLoading = true
  @State private var error: String?
  @State private var hasMoreBefore = false
  @State private var oldestSequence: UInt64?

  var body: some View {
    Group {
      if isLoading {
        ProgressView("Loading conversation...")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let error {
        ContentUnavailableView(
          "Failed to load",
          systemImage: "exclamationmark.triangle",
          description: Text(error)
        )
      } else if messages.isEmpty {
        ContentUnavailableView(
          "No messages yet",
          systemImage: "bubble.left",
          description: Text("This conversation has no messages")
        )
      } else {
        ScrollView {
          if hasMoreBefore {
            Button("Load older messages") {
              loadOlderMessages()
            }
            .padding()
          }

          LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(messages) { message in
              MessageRow(message: message)
            }
          }
          .padding()
        }
        .defaultScrollAnchor(.bottom)
      }
    }
    .navigationTitle(sessionState?.projectName ?? sessionRef.sessionId)
    #if os(macOS)
      .navigationSubtitle(sessionState?.gitBranch ?? "")
    #endif
    .task(id: sessionRef.scopedID) {
      await loadConversation()
    }
  }

  private func loadConversation() async {
    isLoading = true
    error = nil

    do {
      let bootstrap = try await clients.conversation.fetchConversationBootstrap(
        sessionRef.sessionId, limit: 50
      )

      sessionState = bootstrap.session
      hasMoreBefore = bootstrap.hasMoreBefore
      oldestSequence = bootstrap.oldestSequence

      messages = bootstrap.rows.map {
        $0.toTranscriptMessage(endpointId: sessionRef.endpointId)
      }

      isLoading = false
      NSLog("[OrbitDock] Loaded %d messages for session %@", messages.count, sessionRef.sessionId)
    } catch {
      self.error = error.localizedDescription
      isLoading = false
      NSLog("[OrbitDock] Failed to load conversation: %@", error.localizedDescription)
    }
  }

  private func loadOlderMessages() {
    guard let before = oldestSequence else { return }

    Task {
      do {
        let page = try await clients.conversation.fetchConversationHistory(
          sessionRef.sessionId, beforeSequence: before, limit: 50
        )

        let older = page.rows.map {
          $0.toTranscriptMessage(endpointId: sessionRef.endpointId)
        }

        messages.insert(contentsOf: older, at: 0)
        hasMoreBefore = page.hasMoreBefore
        oldestSequence = page.oldestSequence
      } catch {
        NSLog("[OrbitDock] Failed to load older messages: %@", error.localizedDescription)
      }
    }
  }
}

// MARK: - Simple Message Row

struct MessageRow: View {
  let message: TranscriptMessage

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(roleLabel)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(roleColor)
        Spacer()
      }

      if !message.content.isEmpty {
        Text(message.content)
          .font(.system(size: 13))
          .foregroundStyle(Color.textPrimary)
          .textSelection(.enabled)
      }

      if let toolName = message.toolName {
        HStack(spacing: 4) {
          Image(systemName: "wrench")
            .font(.system(size: 10))
          Text(toolName)
            .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(Color.textSecondary)
      }
    }
    .padding(.vertical, 4)
  }

  private var roleLabel: String {
    switch message.type {
    case .user: "You"
    case .assistant: "Assistant"
    case .tool, .toolResult: "Tool"
    default: String(describing: message.type)
    }
  }

  private var roleColor: Color {
    switch message.type {
    case .user: .blue
    case .assistant: Color.statusWorking
    case .tool, .toolResult: Color.textTertiary
    default: Color.textSecondary
    }
  }
}
