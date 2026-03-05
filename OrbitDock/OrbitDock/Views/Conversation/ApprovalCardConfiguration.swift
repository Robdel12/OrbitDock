//
//  ApprovalCardConfiguration.swift
//  OrbitDock
//
//  Shared configuration logic for approval card headers, buttons, and menus.
//  Cross-platform — no AppKit/UIKit dependencies.
//

import SwiftUI

// MARK: - Header Configuration

struct ApprovalHeaderConfig {
  let iconName: String
  let iconTint: Color
  let label: String
  let approveTitle: String
  let denyTitle: String
}

enum ApprovalCardConfiguration {

  static func headerConfig(for model: ApprovalCardModel, mode: ApprovalCardMode) -> ApprovalHeaderConfig {
    switch mode {
      case .permission:
        permissionHeaderConfig(for: model)
      case .question:
        ApprovalHeaderConfig(
          iconName: "questionmark.bubble.fill",
          iconTint: Color.statusQuestion,
          label: "Question",
          approveTitle: "",
          denyTitle: ""
        )
      case .takeover:
        takeoverHeaderConfig(for: model)
      case .none:
        ApprovalHeaderConfig(
          iconName: "questionmark.circle",
          iconTint: Color.textTertiary,
          label: "",
          approveTitle: "",
          denyTitle: ""
        )
    }
  }

  private static func permissionHeaderConfig(for model: ApprovalCardModel) -> ApprovalHeaderConfig {
    let isPlanApproval = model.toolName == "ExitPlanMode"
    if isPlanApproval {
      return ApprovalHeaderConfig(
        iconName: "map.fill",
        iconTint: Color.statusQuestion,
        label: "Exit Plan Mode \u{00B7} Plan Approval",
        approveTitle: "Approve Plan",
        denyTitle: "Revise"
      )
    }
    let toolName = model.toolName ?? "Tool"
    let isPatch = model.approvalType == .patch
    let iconName = isPatch ? "doc.text.fill" : ToolCardStyle.icon(for: toolName)
    let suffix = isPatch ? "File Edit" : "Approval Required"
    return ApprovalHeaderConfig(
      iconName: iconName,
      iconTint: model.risk.tintColor,
      label: "\(toolName) \u{00B7} \(suffix)",
      approveTitle: isPatch ? "Apply" : "Approve",
      denyTitle: "Deny"
    )
  }

  private static func takeoverHeaderConfig(for model: ApprovalCardModel) -> ApprovalHeaderConfig {
    let isPermission = model.approvalType != .question
    if isPermission {
      if let toolName = model.toolName {
        return ApprovalHeaderConfig(
          iconName: ToolCardStyle.icon(for: toolName),
          iconTint: Color.statusPermission,
          label: "\(toolName) \u{00B7} Approval Required",
          approveTitle: "",
          denyTitle: ""
        )
      }
      return ApprovalHeaderConfig(
        iconName: "lock.fill",
        iconTint: Color.statusPermission,
        label: "Approval Required",
        approveTitle: "",
        denyTitle: ""
      )
    }
    return ApprovalHeaderConfig(
      iconName: "questionmark.bubble.fill",
      iconTint: Color.statusQuestion,
      label: "Question Pending",
      approveTitle: "",
      denyTitle: ""
    )
  }

  // MARK: - Menu Action Definitions

  struct MenuAction {
    let title: String
    let iconName: String?
    let keyEquivalent: String
    let decision: String
    let isDestructive: Bool

    init(
      title: String,
      iconName: String? = nil,
      keyEquivalent: String = "",
      decision: String,
      isDestructive: Bool = false
    ) {
      self.title = title
      self.iconName = iconName
      self.keyEquivalent = keyEquivalent
      self.decision = decision
      self.isDestructive = isDestructive
    }
  }

  static func denyMenuActions(for model: ApprovalCardModel?) -> [MenuAction] {
    let isPlan = model?.toolName == "ExitPlanMode"
    return [
      MenuAction(
        title: isPlan ? "Revise Plan" : "Deny",
        iconName: isPlan ? "pencil" : "xmark",
        keyEquivalent: "n",
        decision: "denied"
      ),
      MenuAction(
        title: isPlan ? "Revise with Feedback" : "Deny with Reason",
        iconName: "text.bubble",
        keyEquivalent: "d",
        decision: "deny_reason"
      ),
      MenuAction(
        title: isPlan ? "Reject & Clear Context" : "Deny & Stop",
        iconName: isPlan ? "trash" : "stop.fill",
        keyEquivalent: "N",
        decision: "abort",
        isDestructive: true
      ),
    ]
  }

  static func approveMenuActions(for model: ApprovalCardModel) -> [MenuAction] {
    var actions: [MenuAction] = [
      MenuAction(title: "Approve Once", iconName: "checkmark", keyEquivalent: "y", decision: "approved"),
      MenuAction(
        title: "Allow for Session",
        iconName: "checkmark.seal",
        keyEquivalent: "Y",
        decision: "approved_for_session"
      ),
    ]
    if model.approvalType == .exec, model.hasAmendment {
      actions.append(
        MenuAction(title: "Always Allow", iconName: "checkmark.shield", keyEquivalent: "!", decision: "approved_always")
      )
    }
    return actions
  }

  // MARK: - Takeover Config

  static func takeoverButtonTitle(for model: ApprovalCardModel) -> String {
    let isPermission = model.approvalType != .question
    return isPermission ? "Take Over & Review" : "Take Over & Answer"
  }
}
