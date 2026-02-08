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
  @Environment(ServerAppState.self) private var serverState

  @State private var message = ""
  @State private var isSending = false
  @State private var errorMessage: String?
  @State private var showConfig = false
  @State private var selectedModel: CodexModel = .default
  @State private var selectedEffort: EffortLevel = .default
  @FocusState private var isFocused: Bool

  private var hasOverrides: Bool {
    selectedModel != .default || selectedEffort != .default
  }

  var body: some View {
    VStack(spacing: 0) {
      Divider()

      // Collapsible config row
      if showConfig {
        HStack(spacing: 20) {
          // Model picker
          HStack(spacing: 6) {
            Text("Model")
              .font(.caption)
              .foregroundStyle(.tertiary)
            Picker("Model", selection: $selectedModel) {
              ForEach(CodexModel.allCases) { model in
                Text(model.displayName).tag(model)
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
                selectedModel = .default
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

      HStack(spacing: 12) {
        // Config toggle
        Button {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            showConfig.toggle()
          }
        } label: {
          Image(systemName: "slider.horizontal.3")
            .font(.system(size: 14))
            .foregroundStyle(hasOverrides ? Color.accent : .secondary)
        }
        .buttonStyle(.plain)
        .help("Per-turn config overrides")

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

        // Override indicator (when collapsed and overrides active)
        if !showConfig && hasOverrides {
          overrideBadge
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

  @ViewBuilder
  private var overrideBadge: some View {
    let parts = [
      selectedModel != .default ? selectedModel.displayName : nil,
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
    !isSending && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func sendMessage() {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isSending else { return }

    let model = selectedModel == .default ? nil : selectedModel.rawValue
    let effort = selectedEffort == .default ? nil : selectedEffort.rawValue
    serverState.sendMessage(sessionId: sessionId, content: trimmed, model: model, effort: effort)
    message = ""
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

#Preview {
  CodexInputBar(sessionId: "test-session")
    .environment(ServerAppState())
    .frame(width: 400)
}
