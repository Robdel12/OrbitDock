import SwiftUI

struct DiagnosticsSettingsView: View {
  @State private var copiedCommandID: String?

  private var quickChecks: [DiagnosticsCommand] {
    [
      DiagnosticsCommand(
        id: "status",
        icon: "heart.text.square",
        title: "Server + Auth Summary",
        description: "Confirms OrbitDock is installed, running, and locally reachable.",
        command: "orbitdock status"
      ),
      DiagnosticsCommand(
        id: "server-status",
        icon: "waveform.path.ecg",
        title: "Server Process Health",
        description: "Shows daemon process status and health-check output.",
        command: "orbitdock server status"
      ),
      DiagnosticsCommand(
        id: "session-list",
        icon: "list.bullet.rectangle",
        title: "Session Index",
        description: "Verifies active and recent sessions returned by the server.",
        command: "orbitdock session list"
      ),
    ]
  }

  private var logChecks: [DiagnosticsCommand] {
    [
      DiagnosticsCommand(
        id: "server-errors",
        icon: "exclamationmark.triangle",
        title: "Server Errors Only",
        description: "Streams only error-level server logs with JSON fields intact.",
        command: #"tail -f ~/.orbitdock/logs/server.log | jq 'select(.level == "ERROR")'"#
      ),
      DiagnosticsCommand(
        id: "websocket-events",
        icon: "dot.radiowaves.left.and.right",
        title: "WebSocket Events",
        description: "Tracks handshake and runtime WebSocket transport events.",
        command: #"tail -f ~/.orbitdock/logs/server.log | jq 'select(.component == "websocket")'"#
      ),
      DiagnosticsCommand(
        id: "codex-errors",
        icon: "chevron.left.forwardslash.chevron.right",
        title: "Codex Decode Errors",
        description: "Surfaces decoding and payload mismatches from codex.log.",
        command: #"tail -f ~/.orbitdock/logs/codex.log | jq 'select(.category == "decode" or .level == "error")'"#
      ),
    ]
  }

  private var databaseChecks: [DiagnosticsCommand] {
    [
      DiagnosticsCommand(
        id: "session-state-sql",
        icon: "externaldrive.badge.timemachine",
        title: "Session State Snapshot",
        description: "Reads persisted session work-state directly from SQLite.",
        command: #"sqlite3 ~/.orbitdock/orbitdock.db "SELECT id, work_status FROM sessions LIMIT 10;""#
      ),
      DiagnosticsCommand(
        id: "message-tail-sql",
        icon: "text.bubble",
        title: "Latest Message Rows",
        description: "Checks persisted message ordering for recent timeline rows.",
        command: #"sqlite3 ~/.orbitdock/orbitdock.db "SELECT session_id, sequence, role FROM messages ORDER BY created_at DESC LIMIT 20;""#
      ),
    ]
  }

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        SettingsSection(title: "DIAGNOSTICS", icon: "stethoscope") {
          VStack(alignment: .leading, spacing: Spacing.lg_) {
            Text("Server logs, database files, and hook state are owned by the server and CLI.")
              .font(.system(size: TypeScale.body))
              .foregroundStyle(Color.textSecondary)

            Text(
              "Use the server's diagnostics and admin flows to inspect runtime state. The native client no longer treats those filesystem paths as app-owned resources."
            )
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Spacing.sm_) {
              Image(systemName: "terminal")
                .font(.system(size: TypeScale.micro, weight: .semibold))
                .foregroundStyle(Color.accent)
              Text("Copy a command, then paste it into OrbitDock's embedded terminal or your host shell.")
                .font(.system(size: TypeScale.meta))
                .foregroundStyle(Color.textSecondary)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(
              Color.accent.opacity(OpacityTier.light),
              in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            )
            .overlay(
              RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Color.accent.opacity(0.35), lineWidth: 1)
            )
          }
        }

        SettingsSection(title: "QUICK CHECKS", icon: "bolt.horizontal.circle") {
          commandList(quickChecks)
        }

        SettingsSection(title: "LOG STREAMS", icon: "text.alignleft") {
          commandList(logChecks)
        }

        SettingsSection(title: "DATABASE READS", icon: "externaldrive") {
          commandList(databaseChecks)
        }
      }
      .padding(.horizontal, Spacing.section)
      .padding(.vertical, Spacing.section)
      .frame(maxWidth: 980, alignment: .leading)
    }
  }

  @ViewBuilder
  private func commandList(_ commands: [DiagnosticsCommand]) -> some View {
    VStack(spacing: Spacing.md) {
      ForEach(commands) { command in
        commandCard(command)
      }
    }
  }

  private func commandCard(_ command: DiagnosticsCommand) -> some View {
    let isCopied = copiedCommandID == command.id
    return VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(alignment: .top, spacing: Spacing.md) {
        Image(systemName: command.icon)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.accent)
          .frame(width: 18, alignment: .leading)

        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text(command.title)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text(command.description)
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: Spacing.sm)

        Button {
          Platform.services.copyToClipboard(command.command)
          copiedCommandID = command.id
        } label: {
          Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark.circle.fill" : "doc.on.doc")
            .font(.system(size: TypeScale.meta, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .tint(isCopied ? Color.feedbackPositive : Color.accent)
      }

      Text(command.command)
        .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
        .background(
          Color.backgroundCode.opacity(0.86),
          in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(Color.panelBorder.opacity(0.9), lineWidth: 1)
        )
    }
    .padding(Spacing.md)
    .background(
      Color.backgroundTertiary,
      in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .strokeBorder(Color.surfaceBorder, lineWidth: 1)
    )
  }
}

private struct DiagnosticsCommand: Identifiable {
  let id: String
  let icon: String
  let title: String
  let description: String
  let command: String
}
