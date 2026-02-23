//
//  ApprovalCardModel.swift
//  OrbitDock
//
//  Cross-platform model for inline approval cards in the conversation timeline.
//  Decouples raw session/approval data from native cell rendering.
//

import Foundation

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
  let command: String? // Parsed shell command from toolInput
  let filePath: String? // File path from toolInput (Edit/Write)
  let risk: ApprovalRisk
  let diff: String?
  let question: String?
  let questionId: String?
  let questionHeader: String?
  let questionOptions: [ApprovalQuestionOption]
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
  private struct ParsedQuestionInput {
    let prompts: [ApprovalQuestionPrompt]
  }

  private static func unresolvedApproval(in history: [ServerApprovalHistoryItem]) -> ServerApprovalHistoryItem? {
    history.first { $0.decision == nil && $0.decidedAt == nil }
  }

  private static func parseQuestionOptions(_ rawOptions: Any?) -> [ApprovalQuestionOption] {
    guard let options = rawOptions as? [[String: Any]] else { return [] }
    return options.compactMap { optionDict in
      let label = (optionDict["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? (optionDict["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let label, !label.isEmpty else { return nil }
      let description = (optionDict["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      return ApprovalQuestionOption(
        label: label,
        description: description?.isEmpty == true ? nil : description
      )
    }
  }

  private static func parseBoolean(_ value: Any?) -> Bool {
    switch value {
      case let b as Bool:
        return b
      case let n as NSNumber:
        return n.boolValue
      case let s as String:
        let normalized = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "true" || normalized == "1" || normalized == "yes"
      default:
        return false
    }
  }

  private static func parsePrompt(_ rawQuestion: [String: Any], fallbackId: String) -> ApprovalQuestionPrompt? {
    let question = (rawQuestion["question"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let header = (rawQuestion["header"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let id = (rawQuestion["id"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let options = parseQuestionOptions(rawQuestion["options"])

    let resolvedQuestion = (question?.isEmpty == false ? question : nil) ?? "Question"
    let resolvedId = (id?.isEmpty == false ? id : nil) ?? fallbackId

    let allowsMultipleSelection = parseBoolean(rawQuestion["multiSelect"])
      || parseBoolean(rawQuestion["multi_select"])
    let allowsOther = parseBoolean(rawQuestion["isOther"])
      || parseBoolean(rawQuestion["is_other"])
    let isSecret = parseBoolean(rawQuestion["isSecret"])
      || parseBoolean(rawQuestion["is_secret"])

    return ApprovalQuestionPrompt(
      id: resolvedId,
      header: header?.isEmpty == true ? nil : header,
      question: resolvedQuestion,
      options: options,
      allowsMultipleSelection: allowsMultipleSelection,
      allowsOther: allowsOther,
      isSecret: isSecret
    )
  }

  private static func parseQuestionInput(from toolInput: [String: Any]?) -> ParsedQuestionInput {
    guard let toolInput else {
      return ParsedQuestionInput(prompts: [])
    }

    if let questions = toolInput["questions"] as? [[String: Any]] {
      let prompts = questions.enumerated().compactMap { index, rawQuestion in
        parsePrompt(rawQuestion, fallbackId: String(index))
      }
      return ParsedQuestionInput(prompts: prompts)
    }

    if let prompt = parsePrompt(toolInput, fallbackId: "0") {
      return ParsedQuestionInput(prompts: [prompt])
    }

    return ParsedQuestionInput(prompts: [])
  }

  static func build(
    session: Session,
    pendingApproval: ServerApprovalRequest?,
    serverState: ServerAppState
  ) -> ApprovalCardModel? {
    let pendingHistory = unresolvedApproval(in: serverState.session(session.id).approvalHistory)
    let approvalId = session.pendingApprovalId ?? pendingApproval?.id ?? pendingHistory?.requestId
    let approvalType = pendingApproval?.type ?? pendingHistory?.approvalType

    let mode = ApprovalCardModeResolver.resolve(
      for: session,
      pendingApprovalId: approvalId,
      approvalType: approvalType
    )
    guard mode != .none else { return nil }

    let risk: ApprovalRisk = if let approval = pendingApproval {
      classifyApprovalRisk(type: approval.type, command: approval.command)
    } else if let pendingHistory {
      classifyApprovalRisk(type: pendingHistory.approvalType, command: pendingHistory.command)
    } else {
      .normal
    }

    // Parse toolInput once for both command and filePath extraction
    let rawToolInput = session.pendingToolInput ?? pendingApproval?.toolInputForDisplay
    let inputDict: [String: Any]? = {
      guard let json = rawToolInput,
            let data = json.data(using: .utf8)
      else { return nil }
      return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }()

    // Tool-aware content extraction: try multiple fields to find preview content
    let commandFromInput: String? = {
      guard let dict = inputDict else { return nil }
      // 1. Shell command (Bash)
      if let cmd = String.shellCommandDisplay(from: dict["command"]) { return cmd }
      if let cmd = String.shellCommandDisplay(from: dict["cmd"]) { return cmd }
      // 2. URL (WebFetch, WebSearch)
      if let url = dict["url"] as? String { return url }
      // 3. Query (WebSearch, Grep, Glob, search tools)
      if let query = dict["query"] as? String { return query }
      // 4. Pattern (Grep, Glob)
      if let pattern = dict["pattern"] as? String { return pattern }
      // 5. Prompt (generic description field)
      if let prompt = dict["prompt"] as? String, prompt.count <= 200 { return prompt }
      // 6. Generic fallback: first short string value from the input dict
      for (_, value) in dict {
        if let str = value as? String, !str.isEmpty, str.count <= 200 {
          return str
        }
      }
      return nil
    }()

    let filePathFromInput: String? = {
      guard let dict = inputDict else { return nil }
      return (dict["path"] as? String) ?? (dict["file_path"] as? String)
    }()

    let parsedQuestionInput = parseQuestionInput(from: inputDict)
    let command = commandFromInput ?? pendingApproval?.command ?? pendingHistory?.command
    let filePath = filePathFromInput ?? pendingApproval?.filePath ?? pendingHistory?.filePath
    let toolName = session.pendingToolName ?? pendingApproval?.toolName ?? pendingHistory?.toolName

    var prompts = parsedQuestionInput.prompts
    if prompts.isEmpty,
       let fallbackQuestion = (session.pendingQuestion ?? pendingApproval?.question)?
       .trimmingCharacters(in: .whitespacesAndNewlines),
       !fallbackQuestion.isEmpty
    {
      prompts = [
        ApprovalQuestionPrompt(
          id: "0",
          header: nil,
          question: fallbackQuestion,
          options: [],
          allowsMultipleSelection: false,
          allowsOther: true,
          isSecret: false
        )
      ]
    }
    let firstPrompt = prompts.first

    return ApprovalCardModel(
      mode: mode,
      toolName: toolName,
      command: command,
      filePath: filePath,
      risk: risk,
      diff: pendingApproval?.diff,
      question: firstPrompt?.question,
      questionId: firstPrompt?.id,
      questionHeader: firstPrompt?.header,
      questionOptions: firstPrompt?.options ?? [],
      questions: prompts,
      hasAmendment: pendingApproval?.proposedAmendment != nil || pendingHistory?.proposedAmendment != nil,
      approvalType: approvalType,
      projectPath: session.projectPath,
      approvalId: approvalId,
      sessionId: session.id
    )
  }
}
