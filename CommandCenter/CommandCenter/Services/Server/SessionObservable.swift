//
//  SessionObservable.swift
//  OrbitDock
//
//  Per-session @Observable state. Views observe only the session they display,
//  eliminating cascading re-renders when other sessions update.
//

import Foundation

@Observable
@MainActor
final class SessionObservable {
  let id: String

  // Messages
  var messages: [TranscriptMessage] = []
  private(set) var messagesRevision: Int = 0

  // Approval
  var pendingApproval: ServerApprovalRequest? = nil
  var approvalHistory: [ServerApprovalHistoryItem] = []

  // Session metadata
  var tokenUsage: ServerTokenUsage? = nil
  var diff: String? = nil
  var plan: String? = nil
  var autonomy: AutonomyLevel = .suggest
  var skills: [ServerSkillMetadata] = []

  // Operation flags
  var undoInProgress: Bool = false
  var forkInProgress: Bool = false
  var forkedFrom: String? = nil

  // MCP state
  var mcpTools: [String: ServerMcpTool] = [:]
  var mcpResources: [String: [ServerMcpResource]] = [:]
  var mcpAuthStatuses: [String: ServerMcpAuthStatus] = [:]
  var mcpStartupState: McpStartupState? = nil

  init(id: String) { self.id = id }

  func bumpMessagesRevision() { messagesRevision += 1 }

  var hasMcpData: Bool { !mcpTools.isEmpty || mcpStartupState != nil }

  /// Parse plan JSON string into PlanStep array for UI
  func getPlanSteps() -> [Session.PlanStep]? {
    guard let json = plan,
          let data = json.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return nil }

    let steps = array.compactMap { dict -> Session.PlanStep? in
      guard let step = dict["step"] as? String else { return nil }
      let status = dict["status"] as? String ?? "pending"
      return Session.PlanStep(step: step, status: status)
    }
    return steps.isEmpty ? nil : steps
  }

  /// Clear transient state on session end. Keep messages/tokens/history for viewing.
  func clearTransientState() {
    pendingApproval = nil
    undoInProgress = false
    forkInProgress = false
    mcpTools = [:]
    mcpResources = [:]
    mcpAuthStatuses = [:]
    mcpStartupState = nil
    skills = []
    diff = nil
    plan = nil
  }
}
