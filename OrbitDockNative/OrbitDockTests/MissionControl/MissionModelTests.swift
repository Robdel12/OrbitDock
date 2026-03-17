import Foundation
@testable import OrbitDock
import Testing

struct MissionModelTests {
  /// Models use custom CodingKeys, so no keyDecodingStrategy needed.
  let decoder = JSONDecoder()

  // MARK: - MissionSummary

  @Test func missionSummaryDecodes() throws {
    let json = """
    {
      "id": "m1",
      "name": "Ship features",
      "repo_root": "/Users/dev/my-project",
      "enabled": true,
      "paused": false,
      "tracker_kind": "linear",
      "provider": "claude",
      "provider_strategy": "primary_only",
      "primary_provider": "claude",
      "secondary_provider": "codex",
      "active_count": 3,
      "queued_count": 5,
      "completed_count": 12,
      "failed_count": 1,
      "parse_error": null,
      "orchestrator_status": "polling",
      "last_polled_at": "2026-03-17T10:00:00Z",
      "poll_interval": 30
    }
    """.data(using: .utf8)!

    let summary = try decoder.decode(MissionSummary.self, from: json)
    #expect(summary.id == "m1")
    #expect(summary.name == "Ship features")
    #expect(summary.repoRoot == "/Users/dev/my-project")
    #expect(summary.enabled == true)
    #expect(summary.paused == false)
    #expect(summary.trackerKind == "linear")
    #expect(summary.provider == "claude")
    #expect(summary.providerStrategy == "primary_only")
    #expect(summary.primaryProvider == "claude")
    #expect(summary.secondaryProvider == "codex")
    #expect(summary.activeCount == 3)
    #expect(summary.queuedCount == 5)
    #expect(summary.completedCount == 12)
    #expect(summary.failedCount == 1)
    #expect(summary.parseError == nil)
    #expect(summary.orchestratorStatus == "polling")
    #expect(summary.lastPolledAt == "2026-03-17T10:00:00Z")
    #expect(summary.pollInterval == 30)
  }

  @Test func missionSummaryDecodesWithMissingOptionals() throws {
    let json = """
    {
      "id": "m2",
      "name": "Minimal",
      "repo_root": "/tmp/repo",
      "enabled": false,
      "paused": true,
      "tracker_kind": "linear",
      "provider": "claude",
      "provider_strategy": "primary_only",
      "primary_provider": "claude",
      "active_count": 0,
      "queued_count": 0,
      "completed_count": 0,
      "failed_count": 0
    }
    """.data(using: .utf8)!

    let summary = try decoder.decode(MissionSummary.self, from: json)
    #expect(summary.id == "m2")
    #expect(summary.secondaryProvider == nil)
    #expect(summary.parseError == nil)
    #expect(summary.orchestratorStatus == nil)
    #expect(summary.lastPolledAt == nil)
    #expect(summary.pollInterval == nil)
  }

  // MARK: - MissionSettings

  @Test func missionSettingsDecodesAllNested() throws {
    let json = """
    {
      "provider": {
        "strategy": "primary_only",
        "primary": "claude",
        "secondary": "codex",
        "max_concurrent": 4,
        "max_concurrent_primary": 3
      },
      "agent": {
        "claude": {
          "model": "opus-4",
          "effort": "high",
          "permission_mode": "plan",
          "allowed_tools": ["Read", "Write"],
          "disallowed_tools": ["Bash"]
        },
        "codex": {
          "model": "o3",
          "effort": "medium",
          "approval_policy": "unless-allow-listed",
          "sandbox_mode": "full",
          "collaboration_mode": "single",
          "multi_agent": false,
          "personality": "concise",
          "service_tier": "default",
          "developer_instructions": "Be brief"
        }
      },
      "trigger": {
        "kind": "polling",
        "interval": 30,
        "filters": {
          "labels": ["bug", "feature"],
          "states": ["Todo", "In Progress"],
          "project": "OrbitDock",
          "team": "Engineering"
        }
      },
      "orchestration": {
        "max_retries": 3,
        "stall_timeout": 600,
        "base_branch": "main",
        "worktree_root_dir": "/tmp/worktrees",
        "state_on_dispatch": "In Progress",
        "state_on_complete": "Done"
      },
      "prompt_template": "Fix {{issue.title}}",
      "tracker": "linear"
    }
    """.data(using: .utf8)!

    let settings = try decoder.decode(MissionSettings.self, from: json)

    // Provider
    #expect(settings.provider.strategy == "primary_only")
    #expect(settings.provider.primary == "claude")
    #expect(settings.provider.secondary == "codex")
    #expect(settings.provider.maxConcurrent == 4)
    #expect(settings.provider.maxConcurrentPrimary == 3)

    // Agent — Claude
    let claude = try #require(settings.agent.claude)
    #expect(claude.model == "opus-4")
    #expect(claude.effort == "high")
    #expect(claude.permissionMode == "plan")
    #expect(claude.allowedTools == ["Read", "Write"])
    #expect(claude.disallowedTools == ["Bash"])

    // Agent — Codex
    let codex = try #require(settings.agent.codex)
    #expect(codex.model == "o3")
    #expect(codex.effort == "medium")
    #expect(codex.approvalPolicy == "unless-allow-listed")
    #expect(codex.sandboxMode == "full")
    #expect(codex.collaborationMode == "single")
    #expect(codex.multiAgent == false)
    #expect(codex.personality == "concise")
    #expect(codex.serviceTier == "default")
    #expect(codex.developerInstructions == "Be brief")

    // Trigger
    #expect(settings.trigger.kind == "polling")
    #expect(settings.trigger.interval == 30)
    #expect(settings.trigger.filters.labels == ["bug", "feature"])
    #expect(settings.trigger.filters.states == ["Todo", "In Progress"])
    #expect(settings.trigger.filters.project == "OrbitDock")
    #expect(settings.trigger.filters.team == "Engineering")

    // Orchestration
    #expect(settings.orchestration.maxRetries == 3)
    #expect(settings.orchestration.stallTimeout == 600)
    #expect(settings.orchestration.baseBranch == "main")
    #expect(settings.orchestration.worktreeRootDir == "/tmp/worktrees")
    #expect(settings.orchestration.stateOnDispatch == "In Progress")
    #expect(settings.orchestration.stateOnComplete == "Done")

    // Top-level
    #expect(settings.promptTemplate == "Fix {{issue.title}}")
    #expect(settings.tracker == "linear")
  }

  @Test func missionSettingsDecodesWithMissingOptionals() throws {
    let json = """
    {
      "provider": {
        "strategy": "primary_only",
        "primary": "claude",
        "max_concurrent": 2
      },
      "trigger": {
        "kind": "polling",
        "interval": 60,
        "filters": {}
      },
      "orchestration": {
        "max_retries": 1,
        "stall_timeout": 300,
        "base_branch": "main",
        "state_on_dispatch": "In Progress",
        "state_on_complete": "Done"
      },
      "prompt_template": "Do it",
      "tracker": "linear"
    }
    """.data(using: .utf8)!

    let settings = try decoder.decode(MissionSettings.self, from: json)

    // agent defaults when missing
    #expect(settings.agent.claude == nil)
    #expect(settings.agent.codex == nil)

    // provider optionals
    #expect(settings.provider.secondary == nil)
    #expect(settings.provider.maxConcurrentPrimary == nil)

    // trigger filters default to empty
    #expect(settings.trigger.filters.labels.isEmpty)
    #expect(settings.trigger.filters.states.isEmpty)
    #expect(settings.trigger.filters.project == nil)
    #expect(settings.trigger.filters.team == nil)

    // orchestration optional
    #expect(settings.orchestration.worktreeRootDir == nil)
  }

  // MARK: - MissionIssueItem

  @Test func missionIssueItemDecodes() throws {
    let json = """
    {
      "issue_id": "iss-42",
      "identifier": "ORB-42",
      "title": "Fix login bug",
      "tracker_state": "In Progress",
      "orchestration_state": "running",
      "session_id": "sess-abc",
      "provider": "claude",
      "attempt": 2,
      "error": "Stall detected",
      "url": "https://linear.app/orbitdock/issue/ORB-42",
      "last_activity": "2 minutes ago"
    }
    """.data(using: .utf8)!

    let item = try decoder.decode(MissionIssueItem.self, from: json)
    #expect(item.id == "iss-42")
    #expect(item.issueId == "iss-42")
    #expect(item.identifier == "ORB-42")
    #expect(item.title == "Fix login bug")
    #expect(item.trackerState == "In Progress")
    #expect(item.orchestrationState == .running)
    #expect(item.sessionId == "sess-abc")
    #expect(item.provider == "claude")
    #expect(item.attempt == 2)
    #expect(item.error == "Stall detected")
    #expect(item.url == "https://linear.app/orbitdock/issue/ORB-42")
    #expect(item.lastActivity == "2 minutes ago")
  }

  @Test func missionIssueItemDecodesWithMissingOptionals() throws {
    let json = """
    {
      "issue_id": "iss-99",
      "identifier": "ORB-99",
      "title": "Add dark mode",
      "tracker_state": "Todo",
      "orchestration_state": "queued",
      "provider": "codex",
      "attempt": 1
    }
    """.data(using: .utf8)!

    let item = try decoder.decode(MissionIssueItem.self, from: json)
    #expect(item.sessionId == nil)
    #expect(item.error == nil)
    #expect(item.url == nil)
    #expect(item.lastActivity == nil)
    #expect(item.attempt == 1)
  }

  // MARK: - OrchestrationState

  @Test func orchestrationStateDecodesAllVariants() throws {
    let cases: [(String, OrchestrationState)] = [
      ("\"queued\"", .queued),
      ("\"claimed\"", .claimed),
      ("\"running\"", .running),
      ("\"retry_queued\"", .retryQueued),
      ("\"completed\"", .completed),
      ("\"failed\"", .failed),
    ]

    for (jsonString, expected) in cases {
      let data = try #require(jsonString.data(using: .utf8))
      let state = try decoder.decode(OrchestrationState.self, from: data)
      #expect(state == expected)
    }
  }

  @Test func orchestrationStateFailsOnUnknown() throws {
    let data = "\"exploded\"".data(using: .utf8)!
    #expect(throws: DecodingError.self) {
      _ = try decoder.decode(OrchestrationState.self, from: data)
    }
  }
}
