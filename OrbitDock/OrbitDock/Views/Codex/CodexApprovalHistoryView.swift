//
//  CodexApprovalHistoryView.swift
//  OrbitDock
//

import SwiftUI

struct CodexApprovalHistoryView: View {
  enum Scope: String, CaseIterable, Identifiable {
    case session = "Session"
    case global = "Global"

    var id: String {
      rawValue
    }
  }

  let sessionId: String
  @Environment(ServerAppState.self) private var serverState
  @State private var scope: Scope = .session

  private var currentSession: Session? {
    serverState.sessions.first(where: { $0.id == sessionId })
  }

  private var sessionApprovals: [ServerApprovalHistoryItem] {
    serverState.session(sessionId).approvalHistory.sorted { $0.id > $1.id }
  }

  private var approvals: [ServerApprovalHistoryItem] {
    let source: [ServerApprovalHistoryItem] = switch scope {
      case .session:
        sessionApprovals
      case .global:
        serverState.globalApprovalHistory
    }
    return source.sorted { $0.id > $1.id }
  }

  private var activeScopeGrants: [ServerApprovalHistoryItem] {
    var deduped: [ServerApprovalHistoryItem] = []
    var seen = Set<String>()

    for approval in sessionApprovals {
      guard let decision = approval.decision,
            decision == "approved_for_session" || decision == "approved_always"
      else { continue }

      let key = [
        decision,
        approval.toolName ?? "",
        approval.command ?? "",
        approval.filePath ?? "",
      ].joined(separator: "|")

      if seen.contains(key) {
        continue
      }

      seen.insert(key)
      deduped.append(approval)
    }

    return deduped
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      permissionPosture

      if !activeScopeGrants.isEmpty {
        activeGrantList
      }

      HStack {
        Text("Approval History")
          .font(.headline)
        Spacer()

        Picker("Scope", selection: $scope) {
          ForEach(Scope.allCases) { item in
            Text(item.rawValue).tag(item)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
      }

      if approvals.isEmpty {
        Text("No approvals yet")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ScrollView {
          LazyVStack(spacing: 8) {
            ForEach(approvals) { approval in
              approvalRow(approval)
            }
          }
        }
        .frame(maxHeight: 220)
      }
    }
    .padding(Spacing.md)
    .onAppear {
      serverState.loadApprovalHistory(sessionId: sessionId)
      serverState.loadGlobalApprovalHistory()
    }
    .onChange(of: scope) { _, newScope in
      switch newScope {
        case .session:
          serverState.loadApprovalHistory(sessionId: sessionId)
        case .global:
          serverState.loadGlobalApprovalHistory()
      }
    }
  }

  private var permissionPosture: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Permission Posture")
        .font(.headline)

      if let session = currentSession {
        if session.isDirectCodex {
          let autonomyBinding = Binding(
            get: { serverState.session(sessionId).autonomy },
            set: { newValue in
              serverState.updateSessionConfig(sessionId: sessionId, autonomy: newValue)
            }
          )

          VStack(alignment: .leading, spacing: 6) {
            Picker("Autonomy", selection: autonomyBinding) {
              ForEach(AutonomyLevel.allCases) { level in
                Text(level.displayName).tag(level)
              }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Text(autonomyBinding.wrappedValue.description)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        } else if session.isDirectClaude {
          let permissionBinding = Binding(
            get: { serverState.session(sessionId).permissionMode },
            set: { newValue in
              serverState.updateClaudePermissionMode(sessionId: sessionId, mode: newValue)
            }
          )

          VStack(alignment: .leading, spacing: 6) {
            Picker("Permission Mode", selection: permissionBinding) {
              ForEach(ClaudePermissionMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
              }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Text(permissionBinding.wrappedValue.description)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      } else {
        Text("Session controls unavailable")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text("Session-scoped and always-allow grants are shown below when available.")
        .font(.caption2)
        .foregroundStyle(Color.textTertiary)
    }
    .padding(10)
    .background(Color.backgroundPrimary)
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  private var activeGrantList: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Active Grants")
        .font(.subheadline.weight(.semibold))

      ForEach(activeScopeGrants) { approval in
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(approval.toolName ?? approval.approvalType.rawValue.uppercased())
              .font(.caption.bold())
              .padding(.horizontal, 8)
              .padding(.vertical, 2)
              .background(Color.backgroundTertiary)
              .clipShape(Capsule())

            if let decision = approval.decision {
              Text(decisionLabel(decision))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()
          }

          if let command = approval.command, !command.isEmpty {
            Text(command)
              .font(.system(.caption, design: .monospaced))
              .lineLimit(2)
          } else if let filePath = approval.filePath, !filePath.isEmpty {
            Text(filePath)
              .font(.system(.caption, design: .monospaced))
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        .padding(8)
        .background(Color.backgroundPrimary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  private func approvalRow(_ approval: ServerApprovalHistoryItem) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text(approval.toolName ?? approval.approvalType.rawValue.uppercased())
          .font(.caption.bold())
          .padding(.horizontal, 8)
          .padding(.vertical, 2)
          .background(Color.backgroundTertiary)
          .clipShape(Capsule())

        if let status = approvalStatusLabel(approval) {
          Text(status)
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
          Text("pending")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Button(role: .destructive) {
          serverState.deleteApproval(approvalId: approval.id)
        } label: {
          Image(systemName: "trash")
            .font(.caption)
        }
        .buttonStyle(.plain)
      }

      if let command = approval.command, !command.isEmpty {
        Text(command)
          .font(.system(.caption, design: .monospaced))
          .lineLimit(2)
      } else if let filePath = approval.filePath, !filePath.isEmpty {
        Text(filePath)
          .font(.system(.caption, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.middle)
      }

      HStack {
        Text(approval.sessionId)
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        if let decidedAt = approval.decidedAt {
          Text(relativeTime(decidedAt))
            .font(.caption2)
            .foregroundStyle(Color.textTertiary)
        } else {
          Text(relativeTime(approval.createdAt))
            .font(.caption2)
            .foregroundStyle(Color.textTertiary)
        }
      }
    }
    .padding(8)
    .background(Color.backgroundPrimary)
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func decisionLabel(_ decision: String) -> String {
    switch decision {
      case "approved": "approved once"
      case "approved_for_session": "session-scoped allow"
      case "approved_always": "always allow"
      case "denied": "denied"
      case "abort": "denied & stop"
      default: decision
    }
  }

  private func approvalStatusLabel(_ approval: ServerApprovalHistoryItem) -> String? {
    if let decision = approval.decision {
      return decisionLabel(decision)
    }
    if approval.decidedAt != nil {
      // Defensive fallback: if persisted decision timestamp exists, this is resolved.
      return "approved once"
    }
    if !isLivePending(approval) {
      // If this row is no longer the active pending request in memory,
      // treat it as resolved to avoid sticky "pending" badges from stale payloads.
      return "approved once"
    }
    return nil
  }

  private func isLivePending(_ approval: ServerApprovalHistoryItem) -> Bool {
    guard let pending = serverState.session(approval.sessionId).pendingApproval else { return false }
    guard pending.id == approval.requestId else { return false }

    // request_id can be reused (often "0"), so also try to match payload details.
    if let pendingCommand = pending.command, let rowCommand = approval.command {
      return pendingCommand == rowCommand
    }
    if let pendingPath = pending.filePath, let rowPath = approval.filePath {
      return pendingPath == rowPath
    }
    return true
  }

  private func relativeTime(_ timestamp: String) -> String {
    guard let date = parseTimestamp(timestamp) else { return timestamp }
    return date.formatted(.relative(presentation: .named))
  }

  private func parseTimestamp(_ value: String) -> Date? {
    let stripped = value.hasSuffix("Z") ? String(value.dropLast()) : value
    if let seconds = TimeInterval(stripped) {
      return Date(timeIntervalSince1970: seconds)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}
