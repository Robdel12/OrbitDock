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
  @Environment(CodexDirectSessionManager.self) private var manager

  @State private var message = ""
  @State private var isSending = false
  @State private var errorMessage: String?
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      Divider()

      HStack(spacing: 12) {
        // Text field
        TextField("Send a message...", text: $message, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(1 ... 5)
          .focused($isFocused)
          .disabled(isSending)
          .onSubmit {
            if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              sendMessage()
            }
          }

        // Send button
        Button(action: sendMessage) {
          Group {
            if isSending {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: "arrow.up.circle.fill")
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
  }

  private var canSend: Bool {
    !isSending && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func sendMessage() {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isSending else { return }

    isSending = true
    errorMessage = nil

    Task {
      do {
        try await manager.sendMessage(sessionId, message: trimmed)
        await MainActor.run {
          message = ""
          isSending = false
        }
      } catch {
        await MainActor.run {
          errorMessage = error.localizedDescription
          isSending = false
        }
      }
    }
  }
}

// MARK: - Interrupt Button

struct CodexInterruptButton: View {
  let sessionId: String
  @Environment(CodexDirectSessionManager.self) private var manager

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
    isInterrupting = true

    Task {
      do {
        try await manager.interruptTurn(sessionId)
      } catch {
        // Ignore interrupt errors
      }
      await MainActor.run {
        isInterrupting = false
      }
    }
  }
}

#Preview {
  CodexInputBar(sessionId: "test-session")
    .environment(CodexDirectSessionManager())
    .frame(width: 400)
}
