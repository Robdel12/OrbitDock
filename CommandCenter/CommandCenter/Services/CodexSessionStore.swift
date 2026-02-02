//
//  CodexSessionStore.swift
//  OrbitDock
//
//  SQLite session writer for Codex rollout ingestion.
//

import Foundation
import SQLite

final class CodexSessionStore {
  private let db: Connection
  private let isoFormatter: ISO8601DateFormatter

  init?() {
    let homeDir = FileManager.default.homeDirectoryForCurrentUser
    let dbPath = homeDir.appendingPathComponent(".orbitdock/orbitdock.db").path

    do {
      db = try Connection(dbPath)
      try db.execute("PRAGMA journal_mode = WAL")
      try db.execute("PRAGMA busy_timeout = 5000")
    } catch {
      print("CodexSessionStore: failed to open database - \(error)")
      return nil
    }

    isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    ensureSchema()
  }

  // MARK: - Schema

  private func ensureSchema() {
    // Sessions table is created by hooks, but ensure it exists for fresh installs.
    try? db.execute("""
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        project_path TEXT NOT NULL,
        project_name TEXT,
        branch TEXT,
        model TEXT,
        context_label TEXT,
        custom_name TEXT,
        summary TEXT,
        first_prompt TEXT,
        transcript_path TEXT,
        status TEXT DEFAULT 'active',
        work_status TEXT DEFAULT 'unknown',
        attention_reason TEXT,
        pending_tool_name TEXT,
        pending_tool_input TEXT,
        pending_question TEXT,
        started_at TEXT,
        ended_at TEXT,
        end_reason TEXT,
        total_tokens INTEGER DEFAULT 0,
        total_cost_usd REAL DEFAULT 0,
        last_activity_at TEXT,
        last_tool TEXT,
        last_tool_at TEXT,
        prompt_count INTEGER DEFAULT 0,
        tool_count INTEGER DEFAULT 0,
        terminal_session_id TEXT,
        terminal_app TEXT
      )
    """)
  }

  // MARK: - Sessions

  func sessionExists(_ sessionId: String) -> Bool {
    do {
      let stmt = try db.prepare("SELECT id FROM sessions WHERE id = ? LIMIT 1", sessionId)
      return stmt.makeIterator().next() != nil
    } catch {
      return false
    }
  }

  func upsertSession(
    sessionId: String,
    projectPath: String,
    projectName: String?,
    branch: String?,
    model: String?,
    contextLabel: String?,
    transcriptPath: String?,
    status: String,
    workStatus: String,
    startedAt: String?
  ) {
    let sql = """
      INSERT INTO sessions (
        id, project_path, project_name, branch, model, context_label,
        transcript_path, status, work_status, started_at, last_activity_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
      ON CONFLICT(id) DO UPDATE SET
        project_path = excluded.project_path,
        project_name = excluded.project_name,
        branch = excluded.branch,
        model = excluded.model,
        context_label = excluded.context_label,
        transcript_path = excluded.transcript_path,
        status = excluded.status,
        work_status = excluded.work_status,
        last_activity_at = datetime('now')
    """

    do {
      try db.run(
        sql,
        sessionId,
        projectPath,
        projectName,
        branch,
        model,
        contextLabel,
        transcriptPath,
        status,
        workStatus,
        startedAt ?? isoFormatter.string(from: Date())
      )
    } catch {
      print("CodexSessionStore: upsert failed - \(error)")
    }
  }

  func updateSession(_ sessionId: String, updates: [String: Any?]) {
    let mapped = mapUpdates(updates)
    guard !mapped.setters.isEmpty else { return }

    let sql = "UPDATE sessions SET \(mapped.setters.joined(separator: ", ")), last_activity_at = datetime('now') WHERE id = ?"
    var bindings = mapped.bindings
    bindings.append(sessionId)

    do {
      try db.run(sql, bindings)
    } catch {
      print("CodexSessionStore: update failed - \(error)")
    }
  }

  func updateFirstPromptIfMissing(sessionId: String, prompt: String) {
    do {
      try db.run("UPDATE sessions SET first_prompt = COALESCE(first_prompt, ?) WHERE id = ?", prompt, sessionId)
    } catch {
      print("CodexSessionStore: first_prompt update failed - \(error)")
    }
  }

  func incrementPromptCount(_ sessionId: String) {
    do {
      try db.run("UPDATE sessions SET prompt_count = prompt_count + 1, last_activity_at = datetime('now') WHERE id = ?", sessionId)
    } catch {
      print("CodexSessionStore: prompt_count update failed - \(error)")
    }
  }

  func incrementToolCount(_ sessionId: String) {
    do {
      try db.run("UPDATE sessions SET tool_count = tool_count + 1, last_activity_at = datetime('now') WHERE id = ?", sessionId)
    } catch {
      print("CodexSessionStore: tool_count update failed - \(error)")
    }
  }

  func endSession(_ sessionId: String, reason: String?) {
    do {
      try db.run(
        "UPDATE sessions SET status = 'ended', ended_at = datetime('now'), end_reason = ? WHERE id = ?",
        reason,
        sessionId
      )
    } catch {
      print("CodexSessionStore: end session failed - \(error)")
    }
  }

  func endSessionIfActive(sessionId: String, reason: String?) -> Int {
    do {
      try db.run(
        "UPDATE sessions SET status = 'ended', ended_at = datetime('now'), end_reason = ? WHERE id = ? AND status = 'active'",
        reason,
        sessionId
      )
      return db.changes
    } catch {
      print("CodexSessionStore: end session if active failed - \(error)")
      return 0
    }
  }

  func fetchSessionNameInfo(_ sessionId: String) -> (customName: String?, summary: String?, firstPrompt: String?) {
    do {
      let stmt = try db.prepare(
        "SELECT custom_name, summary, first_prompt FROM sessions WHERE id = ? LIMIT 1",
        sessionId
      )
      if let row = stmt.makeIterator().next() {
        let custom = row[0] as? String
        let summary = row[1] as? String
        let prompt = row[2] as? String
        return (custom, summary, prompt)
      }
    } catch {
      print("CodexSessionStore: fetchSessionNameInfo failed - \(error)")
    }
    return (nil, nil, nil)
  }

  // MARK: - Helpers

  private func findOrCreateRepo(path: String, name: String) -> String? {
    do {
      if let row = try db.prepare("SELECT id FROM repos WHERE path = ? LIMIT 1", path).makeIterator().next(),
         let repoId = row[0] as? String {
        return repoId
      }
    } catch {}

    let repoId = base64URL(path)
    let now = isoFormatter.string(from: Date())

    do {
      try db.run(
        "INSERT INTO repos (id, name, path, created_at) VALUES (?, ?, ?, ?)",
        repoId,
        name,
        path,
        now
      )
      return repoId
    } catch {
      print("CodexSessionStore: create repo failed - \(error)")
      return nil
    }
  }

  private func mapUpdates(_ updates: [String: Any?]) -> (setters: [String], bindings: [Binding?]) {
    let columnMap: [String: String] = [
      "projectPath": "project_path",
      "projectName": "project_name",
      "branch": "branch",
      "model": "model",
      "contextLabel": "context_label",
      "transcriptPath": "transcript_path",
      "status": "status",
      "workStatus": "work_status",
      "startedAt": "started_at",
      "endedAt": "ended_at",
      "endReason": "end_reason",
      "totalTokens": "total_tokens",
      "totalCostUSD": "total_cost_usd",
      "lastTool": "last_tool",
      "lastToolAt": "last_tool_at",
      "promptCount": "prompt_count",
      "toolCount": "tool_count",
      "terminalSessionId": "terminal_session_id",
      "terminalApp": "terminal_app",
      "attentionReason": "attention_reason",
      "pendingToolName": "pending_tool_name",
      "pendingToolInput": "pending_tool_input",
      "pendingQuestion": "pending_question",
      "customName": "custom_name",
      "summary": "summary",
      "firstPrompt": "first_prompt"
    ]

    var setters: [String] = []
    var bindings: [Binding?] = []

    for (key, value) in updates {
      guard let column = columnMap[key] else { continue }
      setters.append("\(column) = ?")
      bindings.append(bindValue(value))
    }

    return (setters, bindings)
  }

  private func bindValue(_ value: Any?) -> Binding? {
    if value is NSNull { return nil }
    if let date = value as? Date {
      return isoFormatter.string(from: date)
    }
    if let string = value as? String {
      return string
    }
    if let int = value as? Int {
      return int
    }
    if let double = value as? Double {
      return double
    }
    if let bool = value as? Bool {
      return bool ? 1 : 0
    }
    return nil
  }

  private func base64URL(_ string: String) -> String {
    let data = Data(string.utf8)
    var encoded = data.base64EncodedString()
    encoded = encoded.replacingOccurrences(of: "+", with: "-")
    encoded = encoded.replacingOccurrences(of: "/", with: "_")
    encoded = encoded.replacingOccurrences(of: "=", with: "")
    return encoded
  }

  private func randomSuffix() -> String {
    let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    var result = ""
    for _ in 0..<6 {
      if let char = letters.randomElement() {
        result.append(char)
      }
    }
    return result
  }
}
