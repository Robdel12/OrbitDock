//
//  CodexTurnStateStore.swift
//  OrbitDock
//
//  In-memory store for Codex turn state (diff, plan).
//  Falls back to database for persistence across app restarts.
//

import Foundation
import SwiftUI

@Observable
@MainActor
final class CodexTurnStateStore {
  static let shared = CodexTurnStateStore()

  /// Current aggregated diff per session (in-memory cache)
  private(set) var diffs: [String: String] = [:]

  /// Current plan per session (in-memory cache)
  private(set) var plans: [String: [Session.PlanStep]] = [:]

  /// Track which sessions we've loaded from DB
  private var loadedFromDB: Set<String> = []

  private init() {}

  // MARK: - Diff

  func updateDiff(sessionId: String, diff: String?) {
    if let diff, !diff.isEmpty {
      diffs[sessionId] = diff
    } else {
      diffs.removeValue(forKey: sessionId)
    }
  }

  func getDiff(sessionId: String) -> String? {
    // Return from cache if available
    if let cached = diffs[sessionId] {
      return cached
    }

    // Try loading from database if we haven't already
    if !loadedFromDB.contains(sessionId) {
      loadedFromDB.insert(sessionId)
      Task { await loadFromDatabase(sessionId: sessionId) }
    }

    return diffs[sessionId]
  }

  // MARK: - Plan

  func updatePlan(sessionId: String, plan: [Session.PlanStep]?) {
    if let plan, !plan.isEmpty {
      plans[sessionId] = plan
    } else {
      plans.removeValue(forKey: sessionId)
    }
  }

  func getPlan(sessionId: String) -> [Session.PlanStep]? {
    // Return from cache if available
    if let cached = plans[sessionId] {
      return cached
    }

    // Try loading from database if we haven't already
    if !loadedFromDB.contains(sessionId) {
      loadedFromDB.insert(sessionId)
      Task { await loadFromDatabase(sessionId: sessionId) }
    }

    return plans[sessionId]
  }

  // MARK: - Clear

  func clearTurnState(sessionId: String) {
    diffs.removeValue(forKey: sessionId)
    plans.removeValue(forKey: sessionId)
  }

  // MARK: - Database Loading

  private func loadFromDatabase(sessionId: String) async {
    // Load diff and plan from database
    let (diff, plan) = await DatabaseManager.shared.fetchCodexTurnState(sessionId: sessionId)

    if let diff, !diff.isEmpty {
      diffs[sessionId] = diff
    }

    if let plan, !plan.isEmpty {
      plans[sessionId] = plan
    }
  }
}
