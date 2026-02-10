//
//  CodexApprovalView.swift
//  OrbitDock
//
//  Inline approval UI for Codex direct sessions.
//  Shows tool details with contextual decision buttons matching codex-core's ReviewDecision.
//

import SwiftUI

struct CodexApprovalView: View {
  let session: Session
  @Environment(ServerAppState.self) private var serverState

  @State private var isProcessing = false
  @State private var errorMessage: String?

  /// Whether this approval has a proposed exec policy amendment (enables "Always Allow")
  private var hasAmendment: Bool {
    serverState.pendingApprovals[session.id]?.proposedAmendment != nil
  }

  /// Whether this is an exec approval (vs patch)
  private var isExecApproval: Bool {
    serverState.pendingApprovals[session.id]?.type == .exec
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Header
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(Color.statusPermission)

        Text("Permission Required")
          .font(.headline)
          .foregroundStyle(.primary)

        Spacer()

        if isProcessing {
          ProgressView()
            .controlSize(.small)
        }
      }

      // Tool details
      if let toolName = session.pendingToolName {
        toolDetailView(toolName: toolName)
      }

      // Error message
      if let error = errorMessage {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      }

      // Primary action buttons
      HStack(spacing: 12) {
        Button(action: { sendDecision("denied") }) {
          HStack(spacing: 4) {
            Image(systemName: "xmark")
            Text("Deny")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .disabled(isProcessing)

        Button(action: { sendDecision("approved") }) {
          HStack(spacing: 4) {
            Image(systemName: "checkmark")
            Text("Approve")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accent)
        .disabled(isProcessing)
      }

      // Secondary options row
      HStack(spacing: 16) {
        Button("Allow This Command for Session") {
          sendDecision("approved_for_session")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .disabled(isProcessing)

        if isExecApproval, hasAmendment {
          Button("Always Allow") {
            sendDecision("approved_always")
          }
          .font(.caption)
          .foregroundStyle(Color.accent)
          .disabled(isProcessing)
        }

        Spacer()

        Button("Deny & Stop") {
          sendDecision("abort")
        }
        .font(.caption)
        .foregroundStyle(.red.opacity(0.8))
        .disabled(isProcessing)
      }

      if isExecApproval {
        Text("Session allow applies only to identical command + working directory.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .background(Color.statusPermission.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.statusPermission.opacity(0.3), lineWidth: 1)
    )
  }

  private func toolDetailView(toolName: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      // Tool badge
      HStack(spacing: 6) {
        Image(systemName: toolIcon(for: toolName))
          .font(.caption)
        Text(toolName)
          .font(.caption.bold())
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Color.backgroundTertiary)
      .clipShape(Capsule())

      // Tool input details
      if let input = parseToolInput() {
        toolInputView(toolName: toolName, input: input)
      }
    }
  }

  @ViewBuilder
  private func toolInputView(toolName: String, input: [String: Any]) -> some View {
    switch toolName {
      case "Shell", "Bash":
        if let command = commandString(from: input) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Command:")
              .font(.caption)
              .foregroundStyle(.secondary)

            Text(command)
              .font(.system(.body, design: .monospaced))
              .padding(8)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(Color.backgroundPrimary)
              .clipShape(RoundedRectangle(cornerRadius: 6))

            Text("Working directory:")
              .font(.caption)
              .foregroundStyle(.secondary)

            Text(session.projectPath)
              .font(.system(.caption, design: .monospaced))
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }

      case "Edit", "Write":
        if let path = (input["path"] as? String) ?? (input["file_path"] as? String) {
          VStack(alignment: .leading, spacing: 4) {
            Text("File:")
              .font(.caption)
              .foregroundStyle(.secondary)

            Text(path)
              .font(.system(.body, design: .monospaced))
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }

      default:
        // Generic JSON display
        if let jsonString = try? JSONSerialization.data(withJSONObject: input, options: .prettyPrinted),
           let text = String(data: jsonString, encoding: .utf8)
        {
          Text(text)
            .font(.system(.caption, design: .monospaced))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.backgroundPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
  }

  private func toolIcon(for toolName: String) -> String {
    switch toolName {
      case "Shell", "Bash": "terminal"
      case "Edit": "pencil"
      case "Write": "doc.badge.plus"
      case "Read": "doc.text"
      default: "wrench"
    }
  }

  private func commandString(from input: [String: Any]) -> String? {
    if let command = input["command"] as? String { return command }
    if let command = input["cmd"] as? String { return command }
    if let commandParts = input["command"] as? [String] { return commandParts.joined(separator: " ") }
    if let commandParts = input["cmd"] as? [String] { return commandParts.joined(separator: " ") }
    return nil
  }

  private func parseToolInput() -> [String: Any]? {
    guard let json = session.pendingToolInput,
          let data = json.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return dict
  }

  private func sendDecision(_ decision: String) {
    guard let requestId = session.pendingApprovalId else { return }
    serverState.approveTool(sessionId: session.id, requestId: requestId, decision: decision)
  }
}

// MARK: - Question Answer View

struct CodexQuestionView: View {
  let session: Session
  @Environment(ServerAppState.self) private var serverState

  @State private var answer = ""
  @State private var isProcessing = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Header
      HStack(spacing: 8) {
        Image(systemName: "questionmark.bubble.fill")
          .foregroundStyle(Color.statusQuestion)

        Text("Question")
          .font(.headline)
          .foregroundStyle(.primary)

        Spacer()

        if isProcessing {
          ProgressView()
            .controlSize(.small)
        }
      }

      // Question text
      if let question = session.pendingQuestion {
        Text(question)
          .font(.body)
          .foregroundStyle(.primary)
      }

      // Answer input
      TextField("Your answer...", text: $answer, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(1 ... 3)
        .disabled(isProcessing)

      // Error message
      if let error = errorMessage {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      }

      // Submit button
      Button(action: submitAnswer) {
        HStack(spacing: 4) {
          Image(systemName: "paperplane.fill")
          Text("Submit")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(Color.accent)
      .disabled(isProcessing || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(16)
    .background(Color.statusQuestion.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.statusQuestion.opacity(0.3), lineWidth: 1)
    )
  }

  private func submitAnswer() {
    guard let requestId = session.pendingApprovalId else { return }
    let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    serverState.answerQuestion(sessionId: session.id, requestId: requestId, answer: trimmed)
    answer = ""
  }
}

#Preview("Approval") {
  CodexApprovalView(
    session: Session(
      id: "test",
      projectPath: "/test",
      status: .active,
      workStatus: .permission,
      attentionReason: .awaitingPermission,
      pendingToolName: "Shell",
      pendingToolInput: #"{"command": "npm install"}"#,
      pendingApprovalId: "req-123"
    )
  )
  .environment(ServerAppState())
  .frame(width: 400)
  .padding()
}

#Preview("Question") {
  CodexQuestionView(
    session: Session(
      id: "test",
      projectPath: "/test",
      status: .active,
      workStatus: .waiting,
      attentionReason: .awaitingQuestion,
      pendingQuestion: "Which database should we use?",
      pendingApprovalId: "req-456"
    )
  )
  .environment(ServerAppState())
  .frame(width: 400)
  .padding()
}
