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

  private var approvals: [ServerApprovalHistoryItem] {
    let source: [ServerApprovalHistoryItem] = switch scope {
      case .session:
        serverState.approvalHistoryBySession[sessionId] ?? []
      case .global:
        serverState.globalApprovalHistory
    }
    return source.sorted { $0.id > $1.id }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
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
    .padding(12)
    .background(Color.backgroundSecondary)
    .clipShape(RoundedRectangle(cornerRadius: 10))
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
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        if let decidedAt = approval.decidedAt {
          Text(relativeTime(decidedAt))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        } else {
          Text(relativeTime(approval.createdAt))
            .font(.caption2)
            .foregroundStyle(.tertiary)
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
    guard let pending = serverState.pendingApprovals[approval.sessionId] else { return false }
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
