//
//  ServerTestView.swift
//  OrbitDock
//
//  Test view for verifying WebSocket connection to Rust server.
//  Access via Settings > Debug > Test Server Connection
//

import SwiftUI

struct ServerTestView: View {
  @StateObject private var connection = ServerConnection.shared
  @State private var sessions: [ServerSessionSummary] = []
  @State private var selectedSession: ServerSessionState?
  @State private var logMessages: [LogMessage] = []
  @State private var newSessionPath = "/tmp/test"

  struct LogMessage: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let text: String
    let isError: Bool
  }

  var body: some View {
    Group {
      #if os(macOS)
        HSplitView {
          sessionsPane
          connectionPane
        }
        .frame(minWidth: 700, minHeight: 400)
      #else
        VStack(spacing: 0) {
          sessionsPane
          Divider()
          connectionPane
        }
      #endif
    }
    .onAppear {
      setupCallbacks()
    }
  }

  // MARK: - Subviews

  private var sessionsPane: some View {
    VStack(alignment: .leading, spacing: 0) {
      header("Sessions")

      if sessions.isEmpty {
        ContentUnavailableView {
          Label("No Sessions", systemImage: "folder.badge.questionmark")
        } description: {
          Text("Create a session or subscribe to the list")
        }
      } else {
        List(sessions) { session in
          sessionRow(session)
        }
      }

      Divider()

      // Create session
      HStack {
        TextField("Project path", text: $newSessionPath)
          .textFieldStyle(.roundedBorder)

        Button("Create") {
          connection.createSession(provider: .codex, cwd: newSessionPath)
          log("Creating session in \(newSessionPath)")
        }
        .disabled(connection.status != .connected)
      }
      .padding()
    }
    .frame(minWidth: 250)
  }

  private var connectionPane: some View {
    VStack(alignment: .leading, spacing: 0) {
      header("Connection")

      // Status
      HStack {
        Circle()
          .fill(statusColor)
          .frame(width: 10, height: 10)

        Text(statusText)
          .font(.headline)

        Spacer()

        if connection.status == .disconnected {
          Button("Connect") {
            connection.connect()
            setupCallbacks()
            log("Connecting...")
          }
          .buttonStyle(.borderedProminent)
        } else {
          Button("Disconnect") {
            connection.disconnect()
            log("Disconnected")
          }
          .buttonStyle(.bordered)
        }
      }
      .padding()

      Divider()

      // Actions
      HStack {
        Button("Subscribe List") {
          connection.subscribeList()
          log("Subscribed to session list")
        }

        if let session = selectedSession {
          Button("Subscribe Session") {
            connection.subscribeSession(session.id)
            log("Subscribed to session \(session.id)")
          }
        }
      }
      .padding(.horizontal)
      .disabled(connection.status != .connected)

      Divider()

      header("Log")

      // Log
      ScrollViewReader { proxy in
        List(logMessages) { msg in
          HStack(alignment: .top) {
            Text(msg.timestamp, style: .time)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)

            Text(msg.text)
              .font(.caption.monospaced())
              .foregroundStyle(msg.isError ? .red : .primary)
          }
          .id(msg.id)
        }
        .onChange(of: logMessages.count) { _, _ in
          if let last = logMessages.last {
            proxy.scrollTo(last.id, anchor: .bottom)
          }
        }
      }
    }
    .frame(minWidth: 400)
  }

  private func header(_ title: String) -> some View {
    Text(title)
      .font(.headline)
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.backgroundSecondary)
  }

  private func sessionRow(_ session: ServerSessionSummary) -> some View {
    VStack(alignment: .leading) {
      Text(session.projectName ?? session.projectPath)
        .font(.headline)

      HStack {
        Text(session.provider.rawValue)
          .font(.caption)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(session.provider == .codex ? Color.orange.opacity(0.2) : Color.blue.opacity(0.2))
          .clipShape(Capsule())

        Text(session.workStatus.rawValue)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }

  private var statusColor: Color {
    switch connection.status {
      case .connected:
        .green
      case .connecting:
        .yellow
      case .disconnected:
        .gray
      case .failed:
        .red
    }
  }

  private var statusText: String {
    switch connection.status {
      case .connected:
        "Connected"
      case .connecting:
        "Connecting..."
      case .disconnected:
        "Disconnected"
      case let .failed(reason):
        "Failed: \(reason)"
    }
  }

  // MARK: - Helpers

  private func log(_ text: String, isError: Bool = false) {
    logMessages.append(LogMessage(text: text, isError: isError))
  }

  private func setupCallbacks() {
    connection.onSessionsList = { sessions in
      self.sessions = sessions
      log("Received \(sessions.count) sessions")
    }

    connection.onSessionSnapshot = { session in
      self.selectedSession = session
      log("Received snapshot for \(session.id)")
    }

    connection.onSessionDelta = { sessionId, _ in
      log("Session \(sessionId) updated")
    }

    connection.onMessageAppended = { sessionId, message in
      log("Message appended to \(sessionId): \(message.content.prefix(50))...")
    }

    connection.onTokensUpdated = { sessionId, usage in
      log("Tokens updated for \(sessionId): \(usage.inputTokens) in, \(usage.outputTokens) out")
    }

    connection.onSessionCreated = { session in
      sessions.append(session)
      log("Session created: \(session.id)")
    }

    connection.onSessionEnded = { sessionId, reason in
      sessions.removeAll { $0.id == sessionId }
      log("Session ended: \(sessionId) - \(reason)")
    }

    connection.onError = { code, message, _ in
      log("Error [\(code)]: \(message)", isError: true)
    }
  }
}

#Preview {
  ServerTestView()
}
