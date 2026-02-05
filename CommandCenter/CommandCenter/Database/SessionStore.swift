//
//  SessionStore.swift
//  OrbitDock
//
//  UI-observable state store for sessions, quests, and inbox items.
//  This is the @Observable layer that SwiftUI views observe.
//  All DB operations go through DatabaseManager actor.
//

import Foundation
import SwiftUI

@Observable
@MainActor
final class SessionStore {
  static let shared = SessionStore()

  // MARK: - Observable State

  /// All sessions, ordered by last activity
  private(set) var sessions: [Session] = []

  /// All quests
  private(set) var allQuests: [Quest] = []

  /// All inbox items
  private(set) var allInboxItems: [InboxItem] = []

  /// Quest details cache
  private(set) var questDetails: [String: Quest] = [:]

  /// Callback for external change notifications
  var onDatabaseChanged: (() -> Void)?

  // MARK: - Private

  private let db = DatabaseManager.shared

  private init() {
    // Subscribe to external changes (CLI writes detected by file watcher)
    // This is the ONLY path for session reloads - all DB writes trigger the file watcher
    DatabaseManager.onExternalChange = { [weak self] in
      self?.notifyExternalChange()
    }

    // NOTE: Removed EventBus.sessionUpdated subscription - it was causing a feedback loop:
    // 1. File watcher → reload() → onDatabaseChanged?() → EventBus.notifyDatabaseChanged()
    // 2. EventBus fires sessionUpdated → reloadSessions() → fetches AGAIN
    // The file watcher already handles all DB changes, so EventBus subscription was redundant.

    // Initial load
    Task {
      await reload()
    }
  }

  // MARK: - Reload All State

  /// Reload all observable state from the database
  func reload() async {
    sessions = await db.fetchSessions()
    allQuests = await db.fetchQuests()
    allInboxItems = await db.fetchInboxItems()
    onDatabaseChanged?()
  }

  /// Reload just sessions
  func reloadSessions() async {
    sessions = await db.fetchSessions()
    onDatabaseChanged?()
  }

  /// Reload just quests
  func reloadQuests() async {
    allQuests = await db.fetchQuests()
    onDatabaseChanged?()
  }

  /// Reload just inbox items
  func reloadInboxItems() async {
    allInboxItems = await db.fetchInboxItems()
    onDatabaseChanged?()
  }

  // MARK: - Session Operations

  func fetchSession(id: String) async -> Session? {
    await db.fetchSession(id: id)
  }

  func fetchSessions(statusFilter: Session.SessionStatus? = nil) async -> [Session] {
    await db.fetchSessions(statusFilter: statusFilter)
  }

  func updateContextLabel(sessionId: String, label: String?) async {
    await db.updateContextLabel(sessionId: sessionId, label: label)
    await reloadSessions()
  }

  func updateCustomName(sessionId: String, name: String?) async {
    await db.updateCustomName(sessionId: sessionId, name: name)
    await reloadSessions()
  }

  func endSession(sessionId: String) async {
    await db.endSession(sessionId: sessionId)
    await reloadSessions()
  }

  func reactivateSession(sessionId: String) async {
    await db.reactivateSession(sessionId: sessionId)
    await reloadSessions()
  }

  // MARK: - Codex Direct Session Operations

  func createCodexDirectSession(
    threadId: String,
    cwd: String,
    model: String? = nil,
    projectName: String? = nil,
    branch: String? = nil,
    transcriptPath: String? = nil
  ) async -> Session? {
    let session = await db.createCodexDirectSession(
      threadId: threadId,
      cwd: cwd,
      model: model,
      projectName: projectName,
      branch: branch,
      transcriptPath: transcriptPath
    )
    await reloadSessions()
    return session
  }

  func updateSessionTranscriptPath(sessionId: String, path: String) async {
    await db.updateSessionTranscriptPath(sessionId: sessionId, path: path)
  }

  func updateCodexDirectSessionStatus(
    sessionId: String,
    workStatus: Session.WorkStatus,
    attentionReason: Session.AttentionReason,
    pendingToolName: String? = nil,
    pendingToolInput: String? = nil,
    pendingQuestion: String? = nil,
    pendingApprovalId: String? = nil
  ) async {
    await db.updateCodexDirectSessionStatus(
      sessionId: sessionId,
      workStatus: workStatus,
      attentionReason: attentionReason,
      pendingToolName: pendingToolName,
      pendingToolInput: pendingToolInput,
      pendingQuestion: pendingQuestion,
      pendingApprovalId: pendingApprovalId
    )
    await reloadSessions()
  }

  func clearCodexPendingApproval(sessionId: String) async {
    await db.clearCodexPendingApproval(sessionId: sessionId)
    await reloadSessions()
  }

  func incrementCodexPromptCount(sessionId: String) async {
    await db.incrementCodexPromptCount(sessionId: sessionId)
  }

  func incrementCodexToolCount(sessionId: String) async {
    await db.incrementCodexToolCount(sessionId: sessionId)
  }

  func updateCodexLastTool(sessionId: String, tool: String) async {
    await db.updateCodexLastTool(sessionId: sessionId, tool: tool)
  }

  func updateCodexTokenUsage(
    sessionId: String,
    inputTokens: Int?,
    outputTokens: Int?,
    cachedTokens: Int?,
    contextWindow: Int?
  ) async {
    await db.updateCodexTokenUsage(
      sessionId: sessionId,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cachedTokens: cachedTokens,
      contextWindow: contextWindow
    )
    await reloadSessions()
  }

  func updateCodexDiff(sessionId: String, diff: String?) async {
    await db.updateCodexDiff(sessionId: sessionId, diff: diff)
  }

  func updateCodexPlan(sessionId: String, plan: [Session.PlanStep]?) async {
    await db.updateCodexPlan(sessionId: sessionId, plan: plan)
  }

  func fetchCodexTurnState(sessionId: String) async -> (diff: String?, plan: [Session.PlanStep]?) {
    await db.fetchCodexTurnState(sessionId: sessionId)
  }

  // MARK: - Quest Operations

  func fetchQuests(status: Quest.Status? = nil) async -> [Quest] {
    await db.fetchQuests(status: status)
  }

  func createQuest(name: String, description: String?, color: String?) async -> Quest? {
    let quest = await db.createQuest(name: name, description: description, color: color)
    await reloadQuests()
    return quest
  }

  func updateQuest(id: String, name: String? = nil, description: String? = nil, status: Quest.Status? = nil, color: String? = nil) async {
    await db.updateQuest(id: id, name: name, description: description, status: status, color: color)
    await reloadQuests()
  }

  func deleteQuest(id: String) async {
    await db.deleteQuest(id: id)
    await reloadQuests()
  }

  func questDetail(id: String) async -> Quest? {
    if let cached = questDetails[id] {
      return cached
    }
    let quest = await db.fetchQuest(id: id)
    if let quest {
      questDetails[id] = quest
    }
    return quest
  }

  func fetchQuest(id: String) async -> Quest? {
    await db.fetchQuest(id: id)
  }

  func linkSessionToQuest(sessionId: String, questId: String) async {
    await db.linkSessionToQuest(sessionId: sessionId, questId: questId)
    await reloadQuests()
  }

  func unlinkSessionFromQuest(sessionId: String, questId: String) async {
    await db.unlinkSessionFromQuest(sessionId: sessionId, questId: questId)
    await reloadQuests()
  }

  func addQuestLink(
    questId: String,
    source: QuestLink.Source,
    url: String,
    title: String? = nil,
    externalId: String? = nil,
    detectedFrom: QuestLink.Detection = .manual
  ) async -> QuestLink? {
    let link = await db.addQuestLink(questId: questId, source: source, url: url, title: title, externalId: externalId, detectedFrom: detectedFrom)
    await reloadQuests()
    return link
  }

  func removeQuestLink(id: String) async {
    await db.removeQuestLink(id: id)
    await reloadQuests()
  }

  func createQuestNote(questId: String, title: String? = nil, content: String) async -> QuestNote? {
    let note = await db.createQuestNote(questId: questId, title: title, content: content)
    await reloadQuests()
    return note
  }

  func updateQuestNote(id: String, title: String? = nil, content: String? = nil) async {
    await db.updateQuestNote(id: id, title: title, content: content)
    await reloadQuests()
  }

  func deleteQuestNote(id: String) async {
    await db.deleteQuestNote(id: id)
    await reloadQuests()
  }

  // MARK: - Inbox Operations

  func captureToInbox(content: String, source: InboxItem.Source = .manual, sessionId: String? = nil) async -> InboxItem? {
    let item = await db.captureToInbox(content: content, source: source, sessionId: sessionId)
    await reloadInboxItems()
    return item
  }

  func attachInboxItem(id: String, toQuest questId: String) async {
    await db.attachInboxItem(id: id, toQuest: questId)
    await reloadInboxItems()
  }

  func markInboxItemDone(id: String) async {
    await db.markInboxItemDone(id: id)
    await reloadInboxItems()
  }

  func deleteInboxItem(id: String) async {
    await db.deleteInboxItem(id: id)
    await reloadInboxItems()
  }

  func detachInboxItem(id: String) async {
    await db.detachInboxItem(id: id)
    await reloadInboxItems()
  }

  func archiveInboxItem(id: String) async {
    await db.archiveInboxItem(id: id)
    await reloadInboxItems()
  }

  func convertInboxItemToLinear(id: String, issueId: String, issueUrl: String) async {
    await db.convertInboxItemToLinear(id: id, issueId: issueId, issueUrl: issueUrl)
    await reloadInboxItems()
  }

  func updateInboxItem(id: String, content: String) async {
    await db.updateInboxItem(id: id, content: content)
    await reloadInboxItems()
  }

  // MARK: - Notification

  /// Called when external changes occur (e.g., CLI writes)
  func notifyExternalChange() {
    Task {
      await reload()
    }
  }
}
