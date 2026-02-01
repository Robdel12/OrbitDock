//
//  CodexRolloutWatcher.swift
//  OrbitDock
//
//  Native Codex rollout watcher using FSEvents.
//  Mirrors hooks behavior by updating session state from rollout JSONL changes.
//

import CoreServices
import Foundation

final class CodexRolloutWatcher {
  static let shared = CodexRolloutWatcher()

  private let queue = DispatchQueue(label: "com.orbitdock.codex.rollout")
  private var stream: FSEventStreamRef?
  private var pendingWork: [String: DispatchWorkItem] = [:]
  private var fileStates: [String: FileState] = [:]

  private let sessionsDir: URL
  private let stateURL: URL
  private var persistedState: PersistedState
  private let watcherStartedAt: Date
  private let debug: Bool
  private let store: CodexSessionStore?

  private init() {
    let homeDir = FileManager.default.homeDirectoryForCurrentUser
    sessionsDir = homeDir.appendingPathComponent(".codex/sessions")
    stateURL = homeDir.appendingPathComponent(".orbitdock/codex-rollout-state.json")
    persistedState = Self.loadState(from: stateURL)
    watcherStartedAt = Date()
    debug = ProcessInfo.processInfo.environment["ORBITDOCK_CODEX_WATCHER_DEBUG"] == "1"
    store = CodexSessionStore()
  }

  func start() {
    guard stream == nil else { return }

    if ProcessInfo.processInfo.environment["ORBITDOCK_DISABLE_CODEX_WATCHER"] == "1" {
      print("CodexRolloutWatcher: disabled by ORBITDOCK_DISABLE_CODEX_WATCHER")
      return
    }

    guard store != nil else {
      print("CodexRolloutWatcher: database unavailable")
      return
    }

    guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
      print("CodexRolloutWatcher: sessions directory missing at \(sessionsDir.path)")
      return
    }

    let callback: FSEventStreamCallback = { _, clientInfo, numEvents, eventPathsPointer, eventFlagsPointer, _ in
      guard let clientInfo else { return }
      let watcher = Unmanaged<CodexRolloutWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
      let paths = unsafeBitCast(eventPathsPointer, to: NSArray.self) as? [String] ?? []

      for index in 0..<Int(numEvents) {
        let path = paths[index]
        let flags = eventFlagsPointer[index]
        watcher.handleEvent(path: path, flags: flags)
      }
    }

    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )

    let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagFileEvents |
        kFSEventStreamCreateFlagNoDefer |
        kFSEventStreamCreateFlagUseCFTypes
    )

    guard let stream = FSEventStreamCreate(
      kCFAllocatorDefault,
      callback,
      &context,
      [sessionsDir.path] as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
      0.2,
      flags
    ) else {
      print("CodexRolloutWatcher: failed to create FSEventStream")
      return
    }

    FSEventStreamSetDispatchQueue(stream, queue)
    FSEventStreamStart(stream)
    self.stream = stream

    print("CodexRolloutWatcher: started (FSEvents on \(sessionsDir.path))")
  }

  func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
    pendingWork.removeAll()
    fileStates.removeAll()
    print("CodexRolloutWatcher: stopped")
  }

  // MARK: - Event Handling

  private func handleEvent(path: String, flags: FSEventStreamEventFlags) {
    let isFile = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)) != 0
    if !isFile { return }

    guard path.hasSuffix(".jsonl") else { return }

    scheduleFile(path)
  }

  private func scheduleFile(_ path: String) {
    pendingWork[path]?.cancel()

    let work = DispatchWorkItem { [weak self] in
      self?.processFile(path)
    }

    pendingWork[path] = work
    queue.asyncAfter(deadline: .now() + 0.15, execute: work)
  }

  private func processFile(_ path: String) {
    guard let store else { return }

    pendingWork[path] = nil

    let fileURL = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else { return }

    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    let createdAt = attributes?[.creationDate] as? Date

    var state = ensureFileState(path: path, size: size, createdAt: createdAt)

    if state.ignoreExisting {
      if size > state.offset {
        state.ignoreExisting = false
        ensureSessionMeta(path: path, state: &state)
      } else {
        state.offset = size
        persistState(path: path, state: state)
        return
      }
    }

    if size < state.offset {
      state.offset = 0
      state.tail = ""
    }

    if size == state.offset {
      persistState(path: path, state: state)
      return
    }

    if state.sessionId == nil {
      ensureSessionMeta(path: path, state: &state)
    }

    guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
    do {
      if state.offset > 0 {
        try handle.seek(toOffset: state.offset)
      }
    } catch {
      try? handle.close()
      return
    }

    let data = handle.readDataToEndOfFile()
    try? handle.close()

    state.offset = size

    guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else {
      persistState(path: path, state: state)
      return
    }

    let combined = state.tail + chunk
    var parts = combined.split(separator: "\n", omittingEmptySubsequences: false)
    let tail = parts.popLast().map(String.init) ?? ""
    state.tail = tail

    var didProcessLines = false

    for part in parts {
      let line = String(part)
      if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
      handleLine(line, path: path, state: &state, store: store)
      didProcessLines = true
    }

    persistState(path: path, state: state)

    if didProcessLines {
      notifyTranscriptUpdated()
    }
  }

  private func handleLine(_ line: String, path: String, state: inout FileState, store: CodexSessionStore) {
    guard let data = line.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return
    }

    guard let type = json["type"] as? String else { return }
    let payload = json["payload"] as? [String: Any]

    switch type {
    case "session_meta":
      if let payload {
        handleSessionMeta(payload, path: path, state: &state, store: store)
      }
    case "turn_context":
      if let payload {
        handleTurnContext(payload, state: &state, store: store)
      }
    case "event_msg":
      if let payload {
        handleEventMsg(payload, state: &state, store: store)
      }
    case "response_item":
      if let payload {
        handleResponseItem(payload, state: &state, store: store)
      }
    default:
      break
    }
  }

  // MARK: - Session Meta

  private func ensureSessionMeta(path: String, state: inout FileState) {
    guard let line = readFirstLine(path) else { return }
    guard let data = line.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String,
          type == "session_meta",
          let payload = json["payload"] as? [String: Any]
    else {
      return
    }

    if let store {
      handleSessionMeta(payload, path: path, state: &state, store: store)
    }
  }

  private func handleSessionMeta(_ payload: [String: Any], path: String, state: inout FileState, store: CodexSessionStore) {
    guard let sessionId = payload["id"] as? String,
          let cwd = payload["cwd"] as? String else { return }

    let modelProvider = payload["model_provider"] as? String
    let originator = payload["originator"] as? String ?? "codex"
    let startedAt = payload["timestamp"] as? String

    let exists = store.sessionExists(sessionId)
    let gitInfo = GitInfo.resolve(for: cwd)

    let projectPath = cwd
    let projectName = gitInfo?.repoName ?? URL(fileURLWithPath: projectPath).lastPathComponent
    let branch = gitInfo?.branch

    let workstreamId: String? = {
      guard let info = gitInfo, info.isFeatureBranch, let repoRoot = info.repoRoot, let repoName = info.repoName else {
        return nil
      }
      let directory = projectPath == repoRoot ? nil : projectPath
      return store.ensureWorkstream(repoPath: repoRoot, repoName: repoName, branch: info.branch ?? "", directory: directory)
    }()

    store.upsertSession(
      sessionId: sessionId,
      projectPath: projectPath,
      projectName: projectName,
      branch: branch,
      model: modelProvider,
      contextLabel: originator,
      transcriptPath: path,
      status: "active",
      workStatus: "unknown",
      startedAt: startedAt,
      workstreamId: workstreamId
    )

    if !exists, let workstreamId {
      store.incrementWorkstreamSessionCount(workstreamId)
    }

    state.sessionId = sessionId
    state.projectPath = projectPath
    state.modelProvider = modelProvider

    notifySessionUpdated()

    if debug {
      print("CodexRolloutWatcher: session meta \(sessionId)")
    }
  }

  // MARK: - Event Handling (Hook Parity)

  private func handleTurnContext(_ payload: [String: Any], state: inout FileState, store: CodexSessionStore) {
    guard let sessionId = state.sessionId else { return }
    var updates: [String: Any?] = [:]

    if let model = payload["model"] as? String {
      updates["model"] = model
    }

    if let cwd = payload["cwd"] as? String, cwd != state.projectPath {
      updates["projectPath"] = cwd
      state.projectPath = cwd
    }

    if !updates.isEmpty {
      store.updateSession(sessionId, updates: updates)
      notifySessionUpdated()
    }
  }

  private func handleEventMsg(_ payload: [String: Any], state: inout FileState, store: CodexSessionStore) {
    guard let sessionId = state.sessionId else { return }
    guard let eventType = payload["type"] as? String else { return }

    switch eventType {
    case "task_started", "turn_started":
      markWorking(sessionId: sessionId, tool: nil, store: store)
      clearPending(sessionId: sessionId, store: store)
    case "task_complete", "turn_complete", "turn_aborted":
      markWaiting(sessionId: sessionId, store: store)
    case "user_message":
      state.sawUserEvent = true
      let message = payload["message"] as? String
      handleUserMessage(sessionId: sessionId, message: message, store: store)
    case "agent_message":
      state.sawAgentEvent = true
      markWaiting(sessionId: sessionId, store: store)
    case "exec_command_begin":
      markWorking(sessionId: sessionId, tool: "Shell", store: store)
    case "exec_command_end":
      markToolCompleted(sessionId: sessionId, tool: "Shell", store: store)
    case "patch_apply_begin":
      markWorking(sessionId: sessionId, tool: "Edit", store: store)
    case "patch_apply_end":
      markToolCompleted(sessionId: sessionId, tool: "Edit", store: store)
    case "mcp_tool_call_begin":
      let label = mcpToolLabel(payload["invocation"] as? [String: Any])
      markWorking(sessionId: sessionId, tool: label, store: store)
    case "mcp_tool_call_end":
      let label = mcpToolLabel(payload["invocation"] as? [String: Any])
      markToolCompleted(sessionId: sessionId, tool: label, store: store)
    case "web_search_begin":
      markWorking(sessionId: sessionId, tool: "WebSearch", store: store)
    case "web_search_end":
      markToolCompleted(sessionId: sessionId, tool: "WebSearch", store: store)
    case "view_image_tool_call":
      markToolCompleted(sessionId: sessionId, tool: "ViewImage", store: store)
    case "exec_approval_request":
      let payloadJson = jsonString(from: payload)
      setPermissionPending(sessionId: sessionId, toolName: "ExecCommand", payload: payloadJson, store: store)
    case "apply_patch_approval_request":
      let payloadJson = jsonString(from: payload)
      setPermissionPending(sessionId: sessionId, toolName: "ApplyPatch", payload: payloadJson, store: store)
    case "request_user_input":
      let question = extractQuestion(from: payload)
      setQuestionPending(sessionId: sessionId, question: question, store: store)
    case "elicitation_request":
      let question = payload["message"] as? String ?? payload["server_name"] as? String
      setQuestionPending(sessionId: sessionId, question: question, store: store)
    case "token_count":
      if let info = payload["info"] as? [String: Any],
         let total = info["total_token_usage"] as? [String: Any],
         let totalTokens = intValue(total["total_tokens"]) {
        store.updateSession(sessionId, updates: ["totalTokens": totalTokens])
        notifySessionUpdated()
      }
    case "thread_name_updated":
      if let name = payload["thread_name"] as? String {
        store.updateSession(sessionId, updates: ["customName": name])
        notifySessionUpdated()
      }
    default:
      break
    }
  }

  private func handleResponseItem(_ payload: [String: Any], state: inout FileState, store: CodexSessionStore) {
    guard let sessionId = state.sessionId else { return }
    guard let payloadType = payload["type"] as? String else { return }

    switch payloadType {
    case "message":
      // Skip response_item messages entirely for Codex - they contain context injection (AGENTS.md, permissions)
      // Real user messages come from event_msg.user_message
      // Real assistant responses come from event_msg.agent_message
      break
    case "function_call":
      guard let callId = payload["call_id"] as? String else { return }
      let toolName = toolLabel(from: payload["name"] as? String)
      if let toolName {
        state.pendingToolCalls[callId] = toolName
        markWorking(sessionId: sessionId, tool: toolName, store: store)
      }
    case "function_call_output":
      if let callId = payload["call_id"] as? String,
         let toolName = state.pendingToolCalls.removeValue(forKey: callId) {
        markToolCompleted(sessionId: sessionId, tool: toolName, store: store)
      }
    default:
      break
    }
  }

  // MARK: - Hook Parity Helpers

  private func handleUserMessage(sessionId: String, message: String?, store: CodexSessionStore) {
    store.incrementPromptCount(sessionId)

    if let message {
      let cleaned = message.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
      if !cleaned.isEmpty {
        let truncated = cleaned.count > 80 ? String(cleaned.prefix(77)) + "..." : cleaned
        store.updateFirstPromptIfMissing(sessionId: sessionId, prompt: truncated)
      }
    }

    store.updateSession(sessionId, updates: [
      "workStatus": "working",
      "attentionReason": "none",
      "pendingQuestion": NSNull()
    ])

    notifySessionUpdated()
  }

  private func setPermissionPending(sessionId: String, toolName: String, payload: String?, store: CodexSessionStore) {
    store.updateSession(sessionId, updates: [
      "workStatus": "permission",
      "attentionReason": "awaitingPermission",
      "pendingToolName": toolName,
      "pendingToolInput": payload ?? NSNull()
    ])

    notifySessionUpdated()
  }

  private func setQuestionPending(sessionId: String, question: String?, store: CodexSessionStore) {
    store.updateSession(sessionId, updates: [
      "workStatus": "waiting",
      "attentionReason": "awaitingQuestion",
      "pendingQuestion": question ?? NSNull()
    ])

    notifySessionUpdated()
  }

  private func clearPending(sessionId: String, store: CodexSessionStore) {
    store.updateSession(sessionId, updates: [
      "pendingToolName": NSNull(),
      "pendingToolInput": NSNull(),
      "pendingQuestion": NSNull()
    ])
  }

  private func markWorking(sessionId: String, tool: String?, store: CodexSessionStore) {
    var updates: [String: Any?] = [
      "workStatus": "working",
      "attentionReason": "none"
    ]

    if let tool {
      updates["lastTool"] = tool
      updates["lastToolAt"] = Date()
    }

    store.updateSession(sessionId, updates: updates)
    notifySessionUpdated()
  }

  private func markToolCompleted(sessionId: String, tool: String?, store: CodexSessionStore) {
    store.incrementToolCount(sessionId)

    var updates: [String: Any?] = [
      "pendingToolName": NSNull(),
      "pendingToolInput": NSNull()
    ]

    if let tool {
      updates["lastTool"] = tool
      updates["lastToolAt"] = Date()
    }

    store.updateSession(sessionId, updates: updates)
    notifySessionUpdated()
  }

  private func markWaiting(sessionId: String, store: CodexSessionStore) {
    store.updateSession(sessionId, updates: [
      "workStatus": "waiting",
      "attentionReason": "awaitingReply",
      "pendingToolName": NSNull(),
      "pendingToolInput": NSNull(),
      "pendingQuestion": NSNull()
    ])

    ensureSessionName(sessionId: sessionId, store: store)
    notifySessionUpdated()
  }

  // MARK: - Utilities

  private func readFirstLine(_ path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    let data = handle.readData(ofLength: 64 * 1024)
    try? handle.close()
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    return text.components(separatedBy: "\n").first
  }

  private func extractMessageText(from payload: [String: Any]) -> String? {
    guard let content = payload["content"] as? [[String: Any]] else { return nil }
    let parts = content.compactMap { $0["text"] as? String }
    let text = parts.joined()
    return text.isEmpty ? nil : text
  }

  private func mcpToolLabel(_ invocation: [String: Any]?) -> String {
    if let server = invocation?["server"] as? String, let tool = invocation?["tool"] as? String {
      return "MCP:\(server)/\(tool)"
    }
    return "MCP"
  }

  private func toolLabel(from raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    switch raw {
    case "exec_command": return "Shell"
    case "patch_apply", "apply_patch": return "Edit"
    case "web_search": return "WebSearch"
    case "view_image": return "ViewImage"
    case "mcp_tool_call": return "MCP"
    default: return raw
    }
  }

  private func extractQuestion(from payload: [String: Any]) -> String? {
    if let questions = payload["questions"] as? [[String: Any]],
       let first = questions.first {
      return (first["question"] as? String) ?? (first["header"] as? String)
    }
    return nil
  }

  private func jsonString(from payload: [String: Any]) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func intValue(_ value: Any?) -> Int? {
    switch value {
    case let int as Int:
      return int
    case let double as Double:
      return Int(double)
    case let string as String:
      return Int(string)
    default:
      return nil
    }
  }

  private func ensureSessionName(sessionId: String, store: CodexSessionStore) {
    let info = store.fetchSessionNameInfo(sessionId)
    if info.customName != nil || info.summary != nil || info.firstPrompt != nil {
      return
    }

    let slug = generateSessionSlug(seed: sessionId)
    store.updateSession(sessionId, updates: ["customName": slug])
  }

  private func generateSessionSlug(seed: String) -> String {
    let adjectives = [
      "Dapper", "Stellar", "Brisk", "Golden", "Gentle", "Clever", "Nimble", "Radiant",
      "Bold", "Quiet", "Swift", "Witty", "Bright", "Calm", "Lucky", "Focused"
    ]
    let verbs = [
      "Soaring", "Gliding", "Orbiting", "Cruising", "Humming", "Tuning", "Weaving", "Drifting",
      "Climbing", "Sailing", "Skimming", "Shaping", "Guiding", "Tracing", "Nesting", "Rolling"
    ]
    let nouns = [
      "Spindle", "Comet", "Beacon", "Canvas", "Signal", "Compass", "Workshop", "Harbor",
      "Circuit", "Pioneer", "Atlas", "Voyager", "Relay", "Forge", "Station", "Rocket"
    ]

    let hash = stableHash(seed)
    let adjective = adjectives[Int(hash % UInt64(adjectives.count))]
    let verb = verbs[Int((hash / 7) % UInt64(verbs.count))]
    let noun = nouns[Int((hash / 31) % UInt64(nouns.count))]
    return "\(adjective) \(verb) \(noun)"
  }

  private func stableHash(_ value: String) -> UInt64 {
    var hash: UInt64 = 5381
    for byte in value.utf8 {
      hash = ((hash << 5) &+ hash) &+ UInt64(byte)
    }
    return hash
  }

  private func notifySessionUpdated() {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    CFNotificationCenterPostNotification(
      center,
      CFNotificationName("com.orbitdock.session.updated" as CFString),
      nil,
      nil,
      true
    )
  }

  private func notifyTranscriptUpdated() {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    CFNotificationCenterPostNotification(
      center,
      CFNotificationName("com.orbitdock.transcript.updated" as CFString),
      nil,
      nil,
      true
    )
  }

  private func ensureFileState(path: String, size: UInt64, createdAt: Date?) -> FileState {
    if let existing = fileStates[path] { return existing }

    if let persisted = persistedState.files[path] {
      let state = FileState(
        offset: persisted.offset,
        tail: "",
        sessionId: persisted.sessionId,
        projectPath: persisted.projectPath,
        modelProvider: persisted.modelProvider,
        ignoreExisting: persisted.ignoreExisting ?? false,
        pendingToolCalls: [:],
        sawUserEvent: false,
        sawAgentEvent: false
      )
      fileStates[path] = state
      return state
    }

    var ignoreExisting = false
    var offset: UInt64 = 0

    if let createdAt, createdAt < watcherStartedAt {
      ignoreExisting = true
      offset = size
    }

    let state = FileState(
      offset: offset,
      tail: "",
      sessionId: nil,
      projectPath: nil,
      modelProvider: nil,
      ignoreExisting: ignoreExisting,
      pendingToolCalls: [:],
      sawUserEvent: false,
      sawAgentEvent: false
    )

    fileStates[path] = state
    return state
  }

  private func persistState(path: String, state: FileState) {
    fileStates[path] = state
    persistedState.files[path] = PersistedFileState(
      offset: state.offset,
      sessionId: state.sessionId,
      projectPath: state.projectPath,
      modelProvider: state.modelProvider,
      ignoreExisting: state.ignoreExisting
    )

    saveState()
  }

  private func saveState() {
    let dir = stateURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    guard let data = try? JSONEncoder().encode(persistedState) else { return }
    try? data.write(to: stateURL, options: .atomic)
  }

  private static func loadState(from url: URL) -> PersistedState {
    guard let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode(PersistedState.self, from: data)
    else {
      return PersistedState(version: 1, files: [:])
    }
    return decoded
  }

  // MARK: - Git

  private struct GitInfo {
    let branch: String?
    let repoRoot: String?
    let repoName: String?
    let isFeatureBranch: Bool

    static func resolve(for path: String) -> GitInfo? {
      let branch = runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: path)
      let repoRoot = runGit(["rev-parse", "--show-toplevel"], cwd: path)
      let name = repoRoot.map { URL(fileURLWithPath: $0).lastPathComponent }
      let isFeature = branch != nil && branch != "main" && branch != "master"
      return GitInfo(branch: branch, repoRoot: repoRoot, repoName: name, isFeatureBranch: isFeature)
    }

    private static func runGit(_ args: [String], cwd: String) -> String? {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = args
      process.currentDirectoryURL = URL(fileURLWithPath: cwd)

      let stdout = Pipe()
      let stderr = Pipe()
      process.standardOutput = stdout
      process.standardError = stderr

      do {
        try process.run()
        process.waitUntilExit()
      } catch {
        return nil
      }

      guard process.terminationStatus == 0 else { return nil }
      let data = stdout.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
      return output?.isEmpty == true ? nil : output
    }
  }

  // MARK: - Types

  private struct FileState {
    var offset: UInt64
    var tail: String
    var sessionId: String?
    var projectPath: String?
    var modelProvider: String?
    var ignoreExisting: Bool
    var pendingToolCalls: [String: String]
    var sawUserEvent: Bool
    var sawAgentEvent: Bool
  }

  private struct PersistedState: Codable {
    var version: Int
    var files: [String: PersistedFileState]
  }

  private struct PersistedFileState: Codable {
    var offset: UInt64
    var sessionId: String?
    var projectPath: String?
    var modelProvider: String?
    var ignoreExisting: Bool?
  }
}
