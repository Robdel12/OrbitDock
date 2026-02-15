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

  @State private var isPulsing = false

  var body: some View {
    HStack(spacing: 0) {
      // Timestamp column placeholder (52px)
      Color.clear
        .frame(width: 52)

      // Status indicator column (20px)
      statusIndicator
        .frame(width: 20, alignment: .center)

      // Status text
      statusContent
        .padding(.leading, Spacing.xs)

      Spacer(minLength: Spacing.xs)
    }
    .padding(.horizontal, Spacing.sm)
    .frame(height: 26)
    .clipped()
    .onAppear {
      if workStatus == .working {
        isPulsing = true
      }
    }
    .onChange(of: workStatus) { _, newValue in
      isPulsing = newValue == .working
    }
  }

  @ViewBuilder
  private var statusIndicator: some View {
    switch workStatus {
    case .working:
      Circle()
        .fill(Color.statusWorking)
        .frame(width: 6, height: 6)
        .opacity(isPulsing ? 0.4 : 1.0)
        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPulsing)

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
            .foregroundStyle(.quaternary)
          Text(tool)
            .font(.system(size: TypeScale.body, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
      }

    case .waiting:
      HStack(spacing: Spacing.xs) {
        Text("Your turn")
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.statusReply)
        Text("\u{00B7}")
          .foregroundStyle(.quaternary)
        Text(provider == .codex ? "Send a message below" : "Respond in terminal")
          .font(.system(size: TypeScale.body))
          .foregroundStyle(.tertiary)
      }

    case .permission:
      HStack(spacing: Spacing.xs) {
        Text("Permission")
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.statusPermission)
        if let toolName = pendingToolName {
          Text("\u{00B7}")
            .foregroundStyle(.quaternary)
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
      if let cmd = (input["command"] as? String) ?? (input["cmd"] as? String) {
        let cleaned = cmd.strippingShellWrapperPrefix()
        return cleaned.count > 50 ? String(cleaned.prefix(47)) + "\u{2026}" : cleaned
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
