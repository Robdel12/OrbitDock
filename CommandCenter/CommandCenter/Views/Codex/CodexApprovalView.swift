//
//  CodexApprovalView.swift
//  OrbitDock
//
//  Inline approval UI for Codex direct sessions.
//  Shows tool details with Approve/Reject buttons.
//

import SwiftUI

struct CodexApprovalView: View {
  let session: Session
  @Environment(CodexDirectSessionManager.self) private var manager

  @State private var isProcessing = false
  @State private var errorMessage: String?

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

      // Action buttons
      HStack(spacing: 12) {
        Button(action: reject) {
          HStack(spacing: 4) {
            Image(systemName: "xmark")
            Text("Reject")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .disabled(isProcessing)

        Button(action: approve) {
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
    }
    .padding(16)
    .background(Color.statusPermission.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.statusPermission.opacity(0.3), lineWidth: 1)
    )
  }

  @ViewBuilder
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
        if let command = input["command"] as? String {
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
          }
        }

      case "Edit", "Write":
        if let path = input["path"] as? String {
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
      case "Shell", "Bash": return "terminal"
      case "Edit": return "pencil"
      case "Write": return "doc.badge.plus"
      case "Read": return "doc.text"
      default: return "wrench"
    }
  }

  private func parseToolInput() -> [String: Any]? {
    guard let json = session.pendingToolInput,
          let data = json.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return dict
  }

  private func approve() {
    guard let requestId = session.pendingApprovalId else { return }
    processApproval(approved: true, requestId: requestId)
  }

  private func reject() {
    guard let requestId = session.pendingApprovalId else { return }
    processApproval(approved: false, requestId: requestId)
  }

  private func processApproval(approved: Bool, requestId: String) {
    isProcessing = true
    errorMessage = nil

    Task {
      do {
        if session.pendingToolName == "Edit" {
          try manager.approvePatch(session.id, requestId: requestId, approved: approved)
        } else {
          try manager.approveExec(session.id, requestId: requestId, approved: approved)
        }
      } catch {
        await MainActor.run {
          errorMessage = error.localizedDescription
          isProcessing = false
        }
      }
    }
  }
}

// MARK: - Question Answer View

struct CodexQuestionView: View {
  let session: Session
  @Environment(CodexDirectSessionManager.self) private var manager

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

    isProcessing = true
    errorMessage = nil

    Task {
      do {
        // For simple questions, use "answer" as the key
        try manager.answerQuestion(session.id, requestId: requestId, answers: ["answer": trimmed])
      } catch {
        await MainActor.run {
          errorMessage = error.localizedDescription
          isProcessing = false
        }
      }
    }
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
  .environment(CodexDirectSessionManager())
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
  .environment(CodexDirectSessionManager())
  .frame(width: 400)
  .padding()
}
