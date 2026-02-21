//
//  WorkStreamLiveIndicator.swift
//  OrbitDock
//
//  Live status indicator at the bottom of the work stream.
//  Same column layout as WorkStreamEntry, but no timestamp.
//

import SwiftUI

struct WorkStreamLiveIndicator: View {
  let workStatus: Session.WorkStatus
  let currentTool: String?
  let currentPrompt: String?
  var pendingToolName: String?
  var pendingToolInput: String?
  var provider: Provider = .claude

  var body: some View {
    HStack(spacing: 0) {
      // Status indicator column (20px)
      statusIndicator
        .frame(width: 20, alignment: .center)

      // Status text
      statusContent
        .padding(.leading, Spacing.xs)

      Spacer(minLength: Spacing.xs)
    }
    .padding(.horizontal, ConversationLayout.metadataHorizontalInset)
    .frame(height: 26)
  }

  @ViewBuilder
  private var statusIndicator: some View {
    switch workStatus {
      case .working:
        Circle()
          .fill(Color.statusWorking)
          .frame(width: 6, height: 6)

      case .waiting:
        Circle()
          .fill(Color.statusReply)
          .frame(width: 6, height: 6)

      case .permission:
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Color.statusPermission)

      case .unknown:
        EmptyView()
    }
  }

  @ViewBuilder
  private var statusContent: some View {
    switch workStatus {
      case .working:
        HStack(spacing: Spacing.xs) {
          Text("Working")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.statusWorking)
          if let tool = currentTool {
            Text("\u{00B7}")
              .foregroundStyle(Color.textQuaternary)
            Text(tool)
              .font(.system(size: TypeScale.body, design: .monospaced))
              .foregroundStyle(Color.textTertiary)
          }
        }

      case .waiting:
        HStack(spacing: Spacing.xs) {
          Text("Your turn")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.statusReply)
          Text("\u{00B7}")
            .foregroundStyle(Color.textQuaternary)
          Text(provider == .codex ? "Send a message below" : "Respond in terminal")
            .font(.system(size: TypeScale.body))
            .foregroundStyle(Color.textTertiary)
        }

      case .permission:
        HStack(spacing: Spacing.xs) {
          Text("Permission")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.statusPermission)
          if let toolName = pendingToolName {
            Text("\u{00B7}")
              .foregroundStyle(Color.textQuaternary)
            Text(toolName)
              .font(.system(size: TypeScale.body, weight: .bold))
              .foregroundStyle(.primary)
          }
          if let detail = permissionDetailText {
            Text(detail)
              .font(.system(size: TypeScale.body, design: .monospaced))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

      case .unknown:
        EmptyView()
    }
  }

  private var permissionDetailText: String? {
    guard let inputJson = pendingToolInput,
          let data = inputJson.data(using: .utf8),
          let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    let toolName = pendingToolName ?? ""
    switch toolName {
      case "Bash":
        if let cmd = String.shellCommandDisplay(from: input["command"])
          ?? String.shellCommandDisplay(from: input["cmd"])
        {
          return cmd.count > 50 ? String(cmd.prefix(47)) + "\u{2026}" : cmd
        }
      case "Edit", "Write", "Read":
        if let path = input["file_path"] as? String {
          return (path as NSString).lastPathComponent
        }
      default:
        break
    }
    return nil
  }
}
