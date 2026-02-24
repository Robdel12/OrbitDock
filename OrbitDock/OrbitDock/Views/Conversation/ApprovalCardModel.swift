//
//  ApprovalCardModel.swift
//  OrbitDock
//
//  Cross-platform model for inline approval cards in the conversation timeline.
//  Decouples raw session/approval data from native cell rendering.
//

import Foundation

enum ApprovalPreviewType: Hashable, Sendable {
  case shellCommand
  case url
  case searchQuery
  case pattern
  case prompt
  case value
  case filePath
  case action

  var title: String {
    switch self {
      case .shellCommand:
        "Shell Command"
      case .url:
        "URL"
      case .searchQuery:
        "Search Query"
      case .pattern:
        "Pattern"
      case .prompt:
        "Prompt"
      case .value:
        "Input"
      case .filePath:
        "File Path"
      case .action:
        "Action"
    }
  }
}

extension ServerApprovalPreviewType {
  var toApprovalPreviewType: ApprovalPreviewType {
    switch self {
      case .shellCommand:
        .shellCommand
      case .url:
        .url
      case .searchQuery:
        .searchQuery
      case .pattern:
        .pattern
      case .prompt:
        .prompt
      case .value:
        .value
      case .filePath:
        .filePath
      case .action:
        .action
    }
  }
}

struct ApprovalQuestionOption: Hashable, Sendable {
  let label: String
  let description: String?
}

struct ApprovalQuestionPrompt: Hashable, Sendable {
  let id: String
  let header: String?
  let question: String
  let options: [ApprovalQuestionOption]
  let allowsMultipleSelection: Bool
  let allowsOther: Bool
  let isSecret: Bool
}

struct ApprovalCardModel: Hashable, Sendable {
  let mode: ApprovalCardMode
  let toolName: String?
  let previewType: ApprovalPreviewType
  let shellSegments: [ApprovalShellSegment]
  let serverManifest: String?
  let decisionScope: String?
  let command: String? // Server-authored preview command/value
  let filePath: String? // Server-authored preview file target
  let risk: ApprovalRisk
  let riskFindings: [String]
  let diff: String?
  let questions: [ApprovalQuestionPrompt]
  let hasAmendment: Bool
  let approvalType: ServerApprovalType?
  let projectPath: String
  let approvalId: String?
  let sessionId: String
}

enum ApprovalCardModeResolver {
  static func resolve(
    for session: Session,
    pendingApprovalId: String? = nil,
    approvalType: ServerApprovalType? = nil
  ) -> ApprovalCardMode {
    if session.canApprove { return .permission }
    if session.canAnswer { return .question }
    if session.canTakeOver { return .takeover }

    let hasPendingApproval = pendingApprovalId != nil
    guard session.needsApprovalOverlay || hasPendingApproval else { return .none }

    // Safety fallback: if state flags are inconsistent but the session is still
    // blocked on an approval/question, surface a takeover path instead of
    // hiding the approval card and trapping the user.
    switch session.attentionReason {
      case .awaitingPermission:
        return session.canSendInput ? .permission : .takeover
      case .awaitingQuestion:
        return session.canSendInput ? .question : .takeover
      case .none, .awaitingReply:
        if approvalType == .question {
          return session.canSendInput ? .question : .takeover
        }
        return session.canSendInput ? .permission : .takeover
    }
  }
}

enum ApprovalCardModelBuilder {
  private static func unresolvedApproval(
    in history: [ServerApprovalHistoryItem],
    requestId: String?
  ) -> ServerApprovalHistoryItem? {
    let unresolved = history.filter { $0.decision == nil && $0.decidedAt == nil }
    if let requestId {
      let normalizedRequestId = requestId.trimmingCharacters(in: .whitespacesAndNewlines)
      if !normalizedRequestId.isEmpty,
         let matching = unresolved.first(where: {
           $0.requestId.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedRequestId
         })
      {
        return matching
      }
    }
    return unresolved.min { $0.id < $1.id }
  }

  private static func mapQuestionOptions(
    _ options: [ServerApprovalQuestionOption]
  ) -> [ApprovalQuestionOption] {
    options.compactMap { option in
      let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !label.isEmpty else { return nil }
      let description = option.description?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return ApprovalQuestionOption(label: label, description: description?.isEmpty == true ? nil : description)
    }
  }

  private static func mapQuestionPrompts(
    _ prompts: [ServerApprovalQuestionPrompt]
  ) -> [ApprovalQuestionPrompt] {
    prompts.compactMap { prompt in
      let id = prompt.id.trimmingCharacters(in: .whitespacesAndNewlines)
      let question = prompt.question.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !id.isEmpty, !question.isEmpty else { return nil }
      let header = prompt.header?.trimmingCharacters(in: .whitespacesAndNewlines)
      return ApprovalQuestionPrompt(
        id: id,
        header: header?.isEmpty == true ? nil : header,
        question: question,
        options: mapQuestionOptions(prompt.options),
        allowsMultipleSelection: prompt.allowsMultipleSelection,
        allowsOther: prompt.allowsOther,
        isSecret: prompt.isSecret
      )
    }
  }

  static func build(
    session: Session,
    pendingApproval: ServerApprovalRequest?,
    serverState: ServerAppState
  ) -> ApprovalCardModel? {
    let queueHeadRequestId = serverState.nextPendingApprovalRequestId(sessionId: session.id) ?? session.pendingApprovalId
    let pendingHistory = unresolvedApproval(
      in: serverState.session(session.id).approvalHistory,
      requestId: queueHeadRequestId
    )
    let approvalId = pendingApproval?.id ?? queueHeadRequestId ?? pendingHistory?.requestId
    let approvalType = pendingApproval?.type ?? pendingHistory?.approvalType

    let mode = ApprovalCardModeResolver.resolve(
      for: session,
      pendingApprovalId: approvalId,
      approvalType: approvalType
    )
    guard mode != .none else { return nil }

    let resolvedApprovalTypeForRisk = pendingApproval?.type ?? pendingHistory?.approvalType ?? approvalType
    let risk = ApprovalRisk.fromServer(
      level: pendingApproval?.preview?.riskLevel,
      approvalType: resolvedApprovalTypeForRisk
    )
    let riskFindings = pendingApproval?.preview?.riskFindings ?? []

    let previewFromServer: (
      command: String?,
      filePath: String?,
      previewType: ApprovalPreviewType,
      shellSegments: [ApprovalShellSegment],
      manifest: String?,
      decisionScope: String?
    )? = {
      guard let preview = pendingApproval?.preview else { return nil }

      let normalizedValue = preview.value.trimmingCharacters(in: .whitespacesAndNewlines)
      let valueForDisplay = normalizedValue.isEmpty ? nil : normalizedValue

      switch preview.type {
        case .filePath:
          guard let path = valueForDisplay else { return nil }
          return (
            command: nil,
            filePath: path,
            previewType: .filePath,
            shellSegments: [],
            manifest: preview.manifest,
            decisionScope: preview.decisionScope
          )
        default:
          let previewType = preview.type.toApprovalPreviewType
          let segments = preview.shellSegments.compactMap { segment -> ApprovalShellSegment? in
            let command = segment.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { return nil }
            return ApprovalShellSegment(command: command, leadingOperator: segment.leadingOperator)
          }
          return (
            command: valueForDisplay,
            filePath: nil,
            previewType: previewType,
            shellSegments: segments,
            manifest: preview.manifest,
            decisionScope: preview.decisionScope
          )
      }
    }()

    let command = previewFromServer?.command
    let filePath = previewFromServer?.filePath
    let toolName = pendingApproval?.toolNameForDisplay ?? session.pendingToolName ?? pendingHistory?.toolName
    let previewType: ApprovalPreviewType = {
      if let serverPreview = previewFromServer {
        return serverPreview.previewType
      }
      return .action
    }()
    let shellSegments = previewFromServer?.shellSegments ?? []
    let serverManifest = previewFromServer?.manifest
    let decisionScope = previewFromServer?.decisionScope

    let prompts = mapQuestionPrompts(pendingApproval?.questionPrompts ?? [])

    return ApprovalCardModel(
      mode: mode,
      toolName: toolName,
      previewType: previewType,
      shellSegments: shellSegments,
      serverManifest: serverManifest,
      decisionScope: decisionScope,
      command: command,
      filePath: filePath,
      risk: risk,
      riskFindings: riskFindings,
      diff: pendingApproval?.diff,
      questions: prompts,
      hasAmendment: pendingApproval?.proposedAmendment != nil || pendingHistory?.proposedAmendment != nil,
      approvalType: approvalType,
      projectPath: session.projectPath,
      approvalId: approvalId,
      sessionId: session.id
    )
  }
}
