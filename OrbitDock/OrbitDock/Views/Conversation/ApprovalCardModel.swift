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
  case diff
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
      case .diff:
        "Diff"
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
      case .diff:
        .diff
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
  let amendmentDetail: String? // Human-readable description of what "Always Allow" would permit
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
    let hasPendingApproval = pendingApprovalId != nil
    guard session.isActive, hasPendingApproval else { return .none }
    if session.canApprove { return .permission }
    if session.canAnswer { return .question }
    if session.canTakeOver { return .takeover }
    if session.canSendInput {
      if session.attentionReason == .awaitingQuestion || approvalType == .question {
        return .question
      }
      return .permission
    }
    return .none
  }
}

enum ApprovalCardModelBuilder {
  private static func normalizedRequestId(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  private static func normalizedText(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  private static func historyItem(
    requestId: String?,
    in approvalHistory: [ServerApprovalHistoryItem]
  ) -> ServerApprovalHistoryItem? {
    guard let requestId else { return nil }
    return approvalHistory.first { item in
      normalizedRequestId(item.requestId) == requestId
    }
  }

  private static func approvalRequest(
    from historyItem: ServerApprovalHistoryItem,
    sessionId: String
  ) -> ServerApprovalRequest {
    ServerApprovalRequest(
      id: historyItem.requestId,
      sessionId: sessionId,
      type: historyItem.approvalType,
      toolName: normalizedText(historyItem.toolName),
      toolInput: normalizedText(historyItem.toolInput),
      command: normalizedText(historyItem.command),
      filePath: normalizedText(historyItem.filePath),
      diff: normalizedText(historyItem.diff),
      question: normalizedText(historyItem.question),
      questionPrompts: historyItem.questionPrompts,
      preview: historyItem.preview,
      proposedAmendment: historyItem.proposedAmendment
    )
  }

  private static func mergedApprovalRequest(
    _ request: ServerApprovalRequest,
    historyItem: ServerApprovalHistoryItem?
  ) -> ServerApprovalRequest {
    guard let historyItem else { return request }

    let mergedToolName = normalizedText(request.toolName) ?? normalizedText(historyItem.toolName)
    let mergedToolInput = normalizedText(request.toolInput) ?? normalizedText(historyItem.toolInput)
    let mergedCommand = normalizedText(request.command) ?? normalizedText(historyItem.command)
    let mergedFilePath = normalizedText(request.filePath) ?? normalizedText(historyItem.filePath)
    let mergedDiff = normalizedText(request.diff) ?? normalizedText(historyItem.diff)
    let mergedQuestion = normalizedText(request.question) ?? normalizedText(historyItem.question)
    let mergedQuestionPrompts = request.questionPrompts.isEmpty
      ? historyItem.questionPrompts
      : request.questionPrompts
    let mergedPreview = request.preview ?? historyItem.preview
    let mergedProposedAmendment = request.proposedAmendment ?? historyItem.proposedAmendment

    if mergedToolName == request.toolName,
       mergedToolInput == request.toolInput,
       mergedCommand == request.command,
       mergedFilePath == request.filePath,
       mergedDiff == request.diff,
       mergedQuestion == request.question,
       mergedQuestionPrompts == request.questionPrompts,
       mergedPreview == request.preview,
       mergedProposedAmendment == request.proposedAmendment
    {
      return request
    }

    return ServerApprovalRequest(
      id: request.id,
      sessionId: request.sessionId,
      type: request.type,
      toolName: mergedToolName,
      toolInput: mergedToolInput,
      command: mergedCommand,
      filePath: mergedFilePath,
      diff: mergedDiff,
      question: mergedQuestion,
      questionPrompts: mergedQuestionPrompts,
      preview: mergedPreview,
      proposedAmendment: mergedProposedAmendment
    )
  }

  private static func planTextFromToolInput(_ toolInput: String?) -> String? {
    guard let toolInput = normalizedText(toolInput),
          let data = toolInput.data(using: .utf8),
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    if let plan = normalizedText(payload["plan"] as? String) {
      return plan
    }
    if let plan = normalizedText(payload["current_plan"] as? String) {
      return plan
    }
    return nil
  }

  private static func latestToolInput(
    for toolName: String,
    in transcriptMessages: [TranscriptMessage]
  ) -> String? {
    let normalizedToolName = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalizedToolName.isEmpty else { return nil }

    for message in transcriptMessages.reversed() {
      guard message.isTool else { continue }
      guard let messageToolName = message.toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            messageToolName == normalizedToolName
      else { continue }
      if let rawToolInput = normalizedText(message.rawToolInput) {
        return rawToolInput
      }
    }
    return nil
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
    approvalHistory: [ServerApprovalHistoryItem] = [],
    transcriptMessages: [TranscriptMessage] = []
  ) -> ApprovalCardModel? {
    let approvalId = normalizedRequestId(session.pendingApprovalId)
    let matchedHistoryItem = historyItem(requestId: approvalId, in: approvalHistory)
    let activePendingApproval: ServerApprovalRequest? = {
      guard let approvalId else { return nil }
      if let pendingApproval, normalizedRequestId(pendingApproval.id) == approvalId {
        return mergedApprovalRequest(pendingApproval, historyItem: matchedHistoryItem)
      }
      if let matchedHistoryItem {
        return approvalRequest(from: matchedHistoryItem, sessionId: session.id)
      }
      return nil
    }()
    let approvalType = activePendingApproval?.type

    let mode = ApprovalCardModeResolver.resolve(
      for: session,
      pendingApprovalId: approvalId,
      approvalType: approvalType
    )
    guard mode != .none else { return nil }
    if mode == .permission || mode == .question, approvalId == nil {
      return nil
    }

    let resolvedApprovalTypeForRisk = activePendingApproval?.type ?? approvalType
    let risk = ApprovalRisk.fromServer(
      level: activePendingApproval?.preview?.riskLevel,
      approvalType: resolvedApprovalTypeForRisk
    )
    let riskFindings = activePendingApproval?.preview?.riskFindings ?? []

    let previewFromServer: (
      command: String?,
      filePath: String?,
      previewType: ApprovalPreviewType,
      shellSegments: [ApprovalShellSegment],
      manifest: String?,
      decisionScope: String?
    )? = {
      guard let preview = activePendingApproval?.preview else { return nil }

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

    let fallbackPreview: (command: String?, filePath: String?, previewType: ApprovalPreviewType)? = {
      guard previewFromServer == nil else { return nil }

      // ExitPlanMode — show descriptive action, not a shell command
      let resolvedToolName = activePendingApproval?.toolNameForDisplay ?? session.pendingToolName ?? nil
      if resolvedToolName == "ExitPlanMode" {
        let planText = planTextFromToolInput(activePendingApproval?.toolInput)
          ?? planTextFromToolInput(session.pendingToolInput)
          ?? planTextFromToolInput(
            latestToolInput(for: "ExitPlanMode", in: transcriptMessages)
          )
        if let planText {
          return (
            command: planText,
            filePath: nil,
            previewType: .prompt
          )
        }
        return (
          command: "Exit plan mode and begin implementation",
          filePath: nil,
          previewType: .action
        )
      }

      if let diff = ApprovalPermissionPreviewHelpers.trimmed(activePendingApproval?.diff) {
        return (command: diff, filePath: nil, previewType: .diff)
      }

      let rawCommand = activePendingApproval?.command ?? nil
      let commandFromApproval = String.shellCommandDisplay(from: rawCommand)
        ?? ApprovalPermissionPreviewHelpers.trimmed(rawCommand)
      let commandFromSession = String.shellCommandDisplay(from: session.pendingToolInput)
        ?? ApprovalPermissionPreviewHelpers.trimmed(session.pendingToolInput)
      let command = commandFromApproval ?? commandFromSession
      let filePath = ApprovalPermissionPreviewHelpers.trimmed(activePendingApproval?.filePath ?? nil)

      if let command {
        return (
          command: command,
          filePath: nil,
          previewType: approvalType == .question ? .prompt : .shellCommand
        )
      }

      if let filePath {
        return (command: nil, filePath: filePath, previewType: .filePath)
      }

      return nil
    }()

    let command = previewFromServer?.command ?? fallbackPreview?.command
    let filePath = previewFromServer?.filePath ?? fallbackPreview?.filePath
    let toolName = activePendingApproval?.toolNameForDisplay ?? session.pendingToolName ?? nil
    let previewType: ApprovalPreviewType = {
      if let serverPreview = previewFromServer {
        return serverPreview.previewType
      }
      if let fallbackPreview {
        return fallbackPreview.previewType
      }
      return .action
    }()
    let shellSegments = previewFromServer?.shellSegments ?? []
    let serverManifest = previewFromServer?.manifest
    let decisionScope = previewFromServer?.decisionScope

    let prompts = mapQuestionPrompts(activePendingApproval?.questionPrompts ?? [])

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
      diff: activePendingApproval?.diff,
      questions: prompts,
      hasAmendment: activePendingApproval?.proposedAmendment != nil,
      amendmentDetail: activePendingApproval?.proposedAmendment.map { parts in
        parts.joined(separator: " ")
      },
      approvalType: approvalType,
      projectPath: session.projectPath,
      approvalId: approvalId,
      sessionId: session.id
    )
  }
}
