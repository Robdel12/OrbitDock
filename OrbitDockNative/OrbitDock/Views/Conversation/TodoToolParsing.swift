//
//  TodoToolParsing.swift
//  OrbitDock
//
//  Shared parsing for TodoWrite/task plan tool payloads.
//

import Foundation

enum TodoToolOperation {
  case write
  case create
  case update
  case list
  case get
  case updatePlan

  init?(toolName: String) {
    let normalized = Self.normalizedName(toolName)
    switch normalized {
      case "todowrite", "todo_write": self = .write
      case "taskcreate", "task_create": self = .create
      case "taskupdate", "task_update": self = .update
      case "tasklist", "task_list": self = .list
      case "taskget", "task_get": self = .get
      case "updateplan", "update_plan": self = .updatePlan
      default: return nil
    }
  }

  private static func normalizedName(_ raw: String) -> String {
    let lowercased = raw.lowercased()
    if lowercased.hasPrefix("mcp__") {
      let parts = lowercased.split(separator: "__")
      if let suffix = parts.last {
        return String(suffix)
      }
    }
    if lowercased.contains(":") {
      let suffix = lowercased.split(separator: ":").last ?? Substring(lowercased)
      return String(suffix)
    }
    return lowercased
  }

  var title: String {
    switch self {
      case .write: "Todos"
      case .create: "Create Task"
      case .update: "Update Task"
      case .list: "List Tasks"
      case .get: "Get Task"
      case .updatePlan: "Plan"
    }
  }

  var defaultStatus: NativeTodoStatus {
    switch self {
      case .write, .create, .list, .get, .updatePlan:
        .pending
      case .update:
        .inProgress
    }
  }
}

enum TodoToolParser {
  struct Payload {
    let title: String
    let subtitle: String?
    let items: [NativeTodoItem]
    let output: String?
  }

  static func payload(
    from message: TranscriptMessage,
    toolName: String,
    supportsRichToolingCards: Bool
  ) -> Payload? {
    guard supportsRichToolingCards else { return nil }
    guard let operation = TodoToolOperation(toolName: toolName) else { return nil }

    let itemsFromOutput = parseOutputTodos(message.sanitizedToolOutput)
    let itemsFromInput = parseInputTodos(message.toolInput, operation: operation)
    let fallbackItem = fallbackItem(input: message.toolInput, defaultStatus: operation.defaultStatus)
    let items: [NativeTodoItem] = {
      if !itemsFromOutput.isEmpty { return itemsFromOutput }
      if !itemsFromInput.isEmpty { return itemsFromInput }
      if let fallbackItem { return [fallbackItem] }
      return []
    }()

    let subtitle = subtitle(for: operation, input: message.toolInput, items: items)
    let output = shouldSuppressOutput(message.sanitizedToolOutput, parsedItems: itemsFromOutput)
      ? nil
      : trimmed(message.sanitizedToolOutput)

    return Payload(title: operation.title, subtitle: subtitle, items: items, output: output)
  }

  static func compactSummary(from message: TranscriptMessage, supportsRichToolingCards: Bool) -> String? {
    guard let toolName = message.toolName,
          TodoToolOperation(toolName: toolName) != nil
    else {
      return nil
    }

    let payload = payload(
      from: message,
      toolName: toolName,
      supportsRichToolingCards: supportsRichToolingCards
    )
    if let active = payload?.items.first(where: { $0.status == .inProgress }) {
      return active.primaryText
    }
    if let pending = payload?.items.first(where: { $0.status == .pending }) {
      return pending.primaryText
    }
    if let first = payload?.items.first {
      return first.primaryText
    }
    if let subtitle = payload?.subtitle, !subtitle.isEmpty {
      return subtitle
    }
    return payload?.title
  }

  private static func subtitle(
    for operation: TodoToolOperation,
    input: [String: Any]?,
    items: [NativeTodoItem]
  ) -> String? {
    if operation == .write {
      guard !items.isEmpty else { return nil }
      let active = items.filter { $0.status == .inProgress }.count
      let completed = items.filter { $0.status == .completed }.count
      var parts = ["\(items.count) items"]
      if active > 0 { parts.append("\(active) active") }
      if completed > 0 { parts.append("\(completed) done") }
      return parts.joined(separator: " · ")
    }

    let subject = trimmed(input?["subject"] as? String)
      ?? trimmed(input?["title"] as? String)
      ?? trimmed(input?["task"] as? String)
    let taskId = trimmed(input?["taskId"] as? String)
      ?? trimmed(input?["task_id"] as? String)
      ?? trimmed(input?["id"] as? String)
    let status = trimmed(input?["status"] as? String)
      .map { $0.replacingOccurrences(of: "_", with: " ").capitalized }

    var parts: [String] = []
    if let subject {
      parts.append(subject)
    } else if let taskId {
      parts.append("Task #\(taskId)")
    }
    if let status {
      parts.append(status)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private static func parseInputTodos(_ input: [String: Any]?, operation: TodoToolOperation) -> [NativeTodoItem] {
    guard let input else { return [] }
    if operation == .updatePlan {
      return parsePlanArray(input["plan"])
    }
    return parseTodoArray(input["todos"])
  }

  private static func parseOutputTodos(_ output: String?) -> [NativeTodoItem] {
    guard let output = trimmed(output),
          let data = output.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data)
    else {
      return []
    }

    if let object = json as? [String: Any] {
      let newTodos = parseTodoArray(object["newTodos"])
      if !newTodos.isEmpty { return newTodos }

      let todos = parseTodoArray(object["todos"])
      if !todos.isEmpty { return todos }

      let oldTodos = parseTodoArray(object["oldTodos"])
      if !oldTodos.isEmpty { return oldTodos }
    }

    if let array = json as? [Any] {
      return parseTodoArray(array)
    }

    return []
  }

  private static func parseTodoArray(_ rawValue: Any?) -> [NativeTodoItem] {
    guard let rawValue else { return [] }
    if let array = rawValue as? [Any] {
      return array.compactMap { rawItem in
        guard let dict = rawItem as? [String: Any] else { return nil }

        let content = trimmed(dict["content"] as? String)
          ?? trimmed(dict["subject"] as? String)
          ?? trimmed(dict["title"] as? String)
        let activeForm = trimmed(dict["activeForm"] as? String)
          ?? trimmed(dict["active_form"] as? String)
        let status = NativeTodoStatus(trimmed(dict["status"] as? String))
        let resolvedContent = content ?? activeForm
        guard let resolvedContent else { return nil }

        return NativeTodoItem(
          content: resolvedContent,
          activeForm: activeForm,
          status: status
        )
      }
    }
    return []
  }

  private static func parsePlanArray(_ rawValue: Any?) -> [NativeTodoItem] {
    guard let rawValue else { return [] }
    if let array = rawValue as? [Any] {
      return array.compactMap { rawItem in
        guard let dict = rawItem as? [String: Any] else { return nil }
        let step = trimmed(dict["step"] as? String)
          ?? trimmed(dict["title"] as? String)
          ?? trimmed(dict["content"] as? String)
        guard let step else { return nil }

        let status = NativeTodoStatus(trimmed(dict["status"] as? String))
        return NativeTodoItem(content: step, activeForm: nil, status: status)
      }
    }
    return []
  }

  private static func fallbackItem(input: [String: Any]?, defaultStatus: NativeTodoStatus) -> NativeTodoItem? {
    guard let input else { return nil }

    let subject = trimmed(input["subject"] as? String)
      ?? trimmed(input["title"] as? String)
      ?? trimmed(input["task"] as? String)
    let taskId = trimmed(input["taskId"] as? String)
      ?? trimmed(input["task_id"] as? String)
      ?? trimmed(input["id"] as? String)
    let description = trimmed(input["description"] as? String)
    let content = subject
      ?? taskId.map { "Task #\($0)" }
      ?? description

    guard let content else { return nil }

    let activeForm = trimmed(input["activeForm"] as? String)
      ?? trimmed(input["active_form"] as? String)
    let parsedStatus = NativeTodoStatus(trimmed(input["status"] as? String))
    let status = parsedStatus == .unknown ? defaultStatus : parsedStatus

    return NativeTodoItem(content: content, activeForm: activeForm, status: status)
  }

  private static func shouldSuppressOutput(_ output: String?, parsedItems: [NativeTodoItem]) -> Bool {
    guard !parsedItems.isEmpty else { return false }
    guard let output = trimmed(output) else { return false }
    return output.hasPrefix("{") || output.hasPrefix("[")
  }

  private static func trimmed(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
