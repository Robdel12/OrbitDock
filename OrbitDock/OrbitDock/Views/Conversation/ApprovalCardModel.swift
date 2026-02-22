//
//  ApprovalCardModel.swift
//  OrbitDock
//
//  Cross-platform model for inline approval cards in the conversation timeline.
//  Decouples raw session/approval data from native cell rendering.
//

import Foundation

struct ApprovalCardModel: Hashable, Sendable {
  let mode: ApprovalCardMode
  let toolName: String?
  let command: String? // Parsed shell command from toolInput
  let filePath: String? // File path from toolInput (Edit/Write)
  let risk: ApprovalRisk
  let diff: String?
  let question: String?
  let hasAmendment: Bool
  let approvalType: ServerApprovalType?
  let projectPath: String
  let approvalId: String?
  let sessionId: String
}

enum ApprovalCardModelBuilder {
  static func build(
    session: Session,
    pendingApproval: ServerApprovalRequest?,
    serverState: ServerAppState
  ) -> ApprovalCardModel? {
    guard session.needsApprovalOverlay else { return nil }

    let mode: ApprovalCardMode
    if session.canApprove {
      mode = .permission
    } else if session.canAnswer {
      mode = .question
    } else if session.canTakeOver {
      mode = .takeover
    } else {
      return nil
    }

    let risk: ApprovalRisk = if let approval = pendingApproval {
      classifyApprovalRisk(type: approval.type, command: approval.command)
    } else {
      .normal
    }

    let command: String? = {
      guard let json = session.pendingToolInput,
            let data = json.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      if let cmd = String.shellCommandDisplay(from: dict["command"]) { return cmd }
      if let cmd = String.shellCommandDisplay(from: dict["cmd"]) { return cmd }
      return nil
    }()

    let filePath: String? = {
      guard let json = session.pendingToolInput,
            let data = json.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      return (dict["path"] as? String) ?? (dict["file_path"] as? String)
    }()

    return ApprovalCardModel(
      mode: mode,
      toolName: session.pendingToolName,
      command: command,
      filePath: filePath,
      risk: risk,
      diff: pendingApproval?.diff,
      question: session.pendingQuestion,
      hasAmendment: pendingApproval?.proposedAmendment != nil,
      approvalType: pendingApproval?.type,
      projectPath: session.projectPath,
      approvalId: session.pendingApprovalId,
      sessionId: session.id
    )
  }
}
