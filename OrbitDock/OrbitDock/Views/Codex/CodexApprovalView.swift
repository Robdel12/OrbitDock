//
//  CodexApprovalView.swift
//  OrbitDock
//
//  Inline approval UI for Codex direct sessions.
//  Risk-classified visual cues, inline diff preview for patches, keyboard shortcuts.
//

import SwiftUI

struct CodexApprovalView: View {
  let session: Session
  @Environment(ServerAppState.self) private var serverState

  @State private var isProcessing = false
  @State private var errorMessage: String?
  @FocusState private var isFocused: Bool
  @State private var isHoveringApprove = false
  @State private var isHoveringDeny = false
  @State private var showDenyMessage = false
  @State private var customDenyMessage: String = ""
  @State private var interruptOnDeny = false

  private var hasAmendment: Bool {
    serverState.session(session.id).pendingApproval?.proposedAmendment != nil
  }

  private var isExecApproval: Bool {
    serverState.session(session.id).pendingApproval?.type == .exec
  }

  private var pendingApproval: ServerApprovalRequest? {
    serverState.session(session.id).pendingApproval
  }

  private var risk: ApprovalRisk {
    guard let approval = pendingApproval else { return .normal }
    return classifyApprovalRisk(type: approval.type, command: approval.command)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // ━━━ Risk severity strip (top edge) ━━━
      risk.tintColor
        .frame(height: 2)
        .shadow(color: risk.tintColor.opacity(0.6), radius: 4, y: 1)

      VStack(alignment: .leading, spacing: Spacing.md) {
        // Header
        HStack(spacing: Spacing.sm) {
          Image(systemName: risk == .high ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: TypeScale.subhead, weight: .semibold))
            .foregroundStyle(risk.tintColor)

          Text("Permission Required")
            .font(.system(size: TypeScale.title, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

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

        // Inline diff preview for patch approvals
        if let diff = pendingApproval?.diff, !diff.isEmpty {
          ApprovalDiffPreview(diffString: diff)
        }

        // Error message
        if let error = errorMessage {
          Text(error)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.statusError)
        }

        // ━━━ Primary actions ━━━
        HStack(spacing: Spacing.sm) {
          // Deny
          approvalButton(
            label: "Deny",
            icon: "xmark",
            hint: "n",
            color: Color.statusError,
            isHovering: isHoveringDeny,
            prominent: false
          ) {
            sendDecision("denied")
          }
          .onHover { isHoveringDeny = $0 }

          // Approve
          approvalButton(
            label: "Approve",
            icon: "checkmark",
            hint: "y",
            color: Color.accent,
            isHovering: isHoveringApprove,
            prominent: true
          ) {
            sendDecision("approved")
          }
          .onHover { isHoveringApprove = $0 }
        }

        // ━━━ Secondary options ━━━
        HStack(spacing: Spacing.md) {
          secondaryAction(label: "Allow for Session", hint: "Y") {
            sendDecision("approved_for_session")
          }

          if isExecApproval, hasAmendment {
            secondaryAction(label: "Always Allow", hint: "!", color: Color.accent) {
              sendDecision("approved_always")
            }
          }

          secondaryAction(label: "Deny with Reason", hint: "d", color: Color.statusError.opacity(0.8)) {
            showDenyMessage.toggle()
          }

          Spacer()

          secondaryAction(label: "Deny & Stop", hint: "N", color: Color.statusError.opacity(0.8)) {
            sendDecision("abort")
          }
        }

        // ━━━ Deny with reason panel ━━━
        if showDenyMessage {
          VStack(alignment: .leading, spacing: Spacing.sm) {
            TextField("Reason for denial...", text: $customDenyMessage, axis: .vertical)
              .textFieldStyle(.roundedBorder)
              .lineLimit(1 ... 3)
              .font(.system(size: TypeScale.code))

            HStack(spacing: Spacing.md) {
              Toggle(isOn: $interruptOnDeny) {
                Text("Interrupt turn")
                  .font(.system(size: TypeScale.caption, weight: .medium))
                  .foregroundStyle(Color.textSecondary)
              }
              .toggleStyle(.checkbox)

              Spacer()

              Button {
                sendDecision("denied")
              } label: {
                HStack(spacing: Spacing.xs) {
                  Image(systemName: "xmark")
                    .font(.system(size: TypeScale.caption, weight: .bold))
                  Text("Send Denial")
                    .font(.system(size: TypeScale.caption, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .background(Color.statusError.opacity(0.75), in: Capsule())
              }
              .buttonStyle(.plain)
              .disabled(customDenyMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
          }
          .padding(Spacing.sm)
          .background(Color.backgroundPrimary.opacity(0.5))
          .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        }

        if isExecApproval {
          Text("Session allow applies only to identical command + working directory.")
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textQuaternary)
        }
      }
      .padding(Spacing.lg)
    }
    .background(risk.tintColor.opacity(risk.tintOpacity))
    .clipShape(RoundedRectangle(cornerRadius: Radius.xl))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.xl)
        .stroke(risk.tintColor.opacity(OpacityTier.medium), lineWidth: 1)
    )
    .shadow(color: risk.tintColor.opacity(0.08), radius: 12, y: 4)
    .focusable()
    .focused($isFocused)
    .onKeyPress(phases: .down) { keyPress in
      guard !isProcessing else { return .ignored }

      switch keyPress.key {
        case KeyEquivalent("y") where !keyPress.modifiers.contains(.shift):
          sendDecision("approved")
          return .handled

        case KeyEquivalent("y") where keyPress.modifiers.contains(.shift),
             KeyEquivalent("Y"):
          sendDecision("approved_for_session")
          return .handled

        case KeyEquivalent("!"):
          if hasAmendment {
            sendDecision("approved_always")
            return .handled
          }
          return .ignored

        case KeyEquivalent("d") where !keyPress.modifiers.contains(.shift):
          showDenyMessage.toggle()
          return .handled

        case KeyEquivalent("n") where !keyPress.modifiers.contains(.shift):
          sendDecision("denied")
          return .handled

        case KeyEquivalent("n") where keyPress.modifiers.contains(.shift),
             KeyEquivalent("N"):
          sendDecision("abort")
          return .handled

        default:
          return .ignored
      }
    }
    .onChange(of: session.canApprove) { _, canApprove in
      if canApprove {
        isFocused = true
      }
    }
  }

  // MARK: - Primary Action Button

  private func approvalButton(
    label: String,
    icon: String,
    hint: String,
    color: Color,
    isHovering: Bool,
    prominent: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: icon)
          .font(.system(size: TypeScale.body, weight: .bold))
        Text(label)
          .font(.system(size: TypeScale.code, weight: .semibold))

        Spacer()

        keyHint(hint)
      }
      .foregroundStyle(prominent ? .white : color)
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .frame(maxWidth: .infinity)
      .background(
        prominent
          ? AnyShapeStyle(color.opacity(isHovering ? 0.9 : 0.75))
          : AnyShapeStyle(color.opacity(isHovering ? OpacityTier.medium : OpacityTier.light))
      )
      .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
      .shadow(
        color: prominent && isHovering ? color.opacity(0.3) : .clear,
        radius: 8,
        y: 0
      )
    }
    .buttonStyle(.plain)
    .disabled(isProcessing)
    .animation(.easeOut(duration: 0.15), value: isHovering)
  }

  // MARK: - Secondary Action

  private func secondaryAction(
    label: String,
    hint: String,
    color: Color = .secondary,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: Spacing.xs) {
        Text(label)
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(color)
        keyHint(hint)
      }
    }
    .buttonStyle(.plain)
    .disabled(isProcessing)
  }

  // MARK: - Tool Detail

  private func toolDetailView(toolName: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      // Tool badge + risk badge
      HStack(spacing: Spacing.sm) {
        HStack(spacing: Spacing.xs) {
          Image(systemName: ToolCardStyle.icon(for: toolName))
            .font(.system(size: TypeScale.caption))
          Text(toolName)
            .font(.system(size: TypeScale.caption, weight: .bold))
        }
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color.backgroundTertiary)
        .clipShape(Capsule())

        if risk == .high {
          HStack(spacing: 3) {
            Image(systemName: "bolt.trianglebadge.exclamationmark.fill")
              .font(.system(size: TypeScale.micro))
            Text("DESTRUCTIVE")
              .font(.system(size: TypeScale.micro, weight: .black))
          }
          .foregroundStyle(.white)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, 2)
          .background(Color.statusError, in: Capsule())
        }
      }

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
          VStack(alignment: .leading, spacing: Spacing.sm) {
            // Command block with left edge accent
            HStack(spacing: 0) {
              Rectangle()
                .fill(risk.tintColor)
                .frame(width: EdgeBar.width)

              Text(command)
                .font(.system(size: TypeScale.code, design: .monospaced))
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.backgroundPrimary)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))

            // Working directory — compact inline
            HStack(spacing: Spacing.xs) {
              Image(systemName: "folder")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textQuaternary)
              Text(session.projectPath)
                .font(.system(size: TypeScale.caption, design: .monospaced))
                .foregroundStyle(Color.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
          }
        }

      case "Edit", "Write":
        if let path = (input["path"] as? String) ?? (input["file_path"] as? String) {
          HStack(spacing: 0) {
            Rectangle()
              .fill(risk.tintColor)
              .frame(width: EdgeBar.width)

            HStack(spacing: Spacing.sm) {
              Image(systemName: toolName == "Edit" ? "pencil" : "doc.badge.plus")
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Color.textTertiary)
              Text(path)
                .font(.system(size: TypeScale.code, design: .monospaced))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .background(Color.backgroundPrimary)
          .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        }

      default:
        if let jsonString = try? JSONSerialization.data(withJSONObject: input, options: .prettyPrinted),
           let text = String(data: jsonString, encoding: .utf8)
        {
          HStack(spacing: 0) {
            Rectangle()
              .fill(risk.tintColor)
              .frame(width: EdgeBar.width)

            Text(text)
              .font(.system(size: TypeScale.caption, design: .monospaced))
              .foregroundStyle(Color.textSecondary)
              .padding(.horizontal, Spacing.md)
              .padding(.vertical, Spacing.sm)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .background(Color.backgroundPrimary)
          .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        }
    }
  }

  // MARK: - Key Hint Capsule

  private func keyHint(_ key: String) -> some View {
    Text(key)
      .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
      .foregroundStyle(Color.textTertiary)
      .frame(width: 16, height: 16)
      .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
      .overlay(
        RoundedRectangle(cornerRadius: 3)
          .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
      )
  }

  // MARK: - Helpers

  private func commandString(from input: [String: Any]) -> String? {
    if let command = String.shellCommandDisplay(from: input["command"]) { return command }
    if let command = String.shellCommandDisplay(from: input["cmd"]) { return command }
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

    let denyMessage: String? = (decision == "denied" && showDenyMessage && !customDenyMessage
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      ? customDenyMessage.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    let interrupt: Bool? = (decision == "denied" && interruptOnDeny) ? true : nil

    serverState.approveTool(
      sessionId: session.id,
      requestId: requestId,
      decision: decision,
      message: denyMessage,
      interrupt: interrupt
    )

    showDenyMessage = false
    customDenyMessage = ""
    interruptOnDeny = false
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
    VStack(alignment: .leading, spacing: 0) {
      // Severity strip
      Color.statusQuestion
        .frame(height: 2)
        .shadow(color: Color.statusQuestion.opacity(0.6), radius: 4, y: 1)

      VStack(alignment: .leading, spacing: Spacing.md) {
        // Header
        HStack(spacing: Spacing.sm) {
          Image(systemName: "questionmark.bubble.fill")
            .font(.system(size: TypeScale.subhead, weight: .semibold))
            .foregroundStyle(Color.statusQuestion)

          Text("Question")
            .font(.system(size: TypeScale.title, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Spacer()

          if isProcessing {
            ProgressView()
              .controlSize(.small)
          }
        }

        // Question text
        if let question = session.pendingQuestion {
          Text(question)
            .font(.system(size: TypeScale.reading))
            .foregroundStyle(Color.textPrimary)
        }

        // Answer input
        TextField("Your answer...", text: $answer, axis: .vertical)
          .textFieldStyle(.roundedBorder)
          .lineLimit(1 ... 3)
          .disabled(isProcessing)

        // Error message
        if let error = errorMessage {
          Text(error)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.statusError)
        }

        // Submit button
        Button(action: submitAnswer) {
          HStack(spacing: Spacing.sm) {
            Image(systemName: "paperplane.fill")
              .font(.system(size: TypeScale.body, weight: .bold))
            Text("Submit")
              .font(.system(size: TypeScale.code, weight: .semibold))
          }
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .padding(.vertical, Spacing.sm)
          .background(Color.statusQuestion.opacity(0.75))
          .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isProcessing || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding(Spacing.lg)
    }
    .background(Color.statusQuestion.opacity(OpacityTier.light))
    .clipShape(RoundedRectangle(cornerRadius: Radius.xl))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.xl)
        .stroke(Color.statusQuestion.opacity(OpacityTier.medium), lineWidth: 1)
    )
    .shadow(color: Color.statusQuestion.opacity(0.08), radius: 12, y: 4)
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
