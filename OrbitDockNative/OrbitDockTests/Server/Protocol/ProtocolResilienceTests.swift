import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ProtocolResilienceTests {
  // MARK: - Part 1: Unknown Type Resilience

  @Test func unknownMessageTypeDecodesWithoutThrowing() throws {
    let json = Data("""
    {"type": "quantum_entanglement_sync", "session_id": "s-1"}
    """.utf8)

    let message = try JSONDecoder().decode(ServerToClientMessage.self, from: json)

    guard case let .unknown(type) = message else {
      Issue.record("Expected .unknown, got \(message)")
      return
    }
    #expect(type == "quantum_entanglement_sync")
  }

  @Test func unknownRowTypeDecodesGracefully() throws {
    let json = Data("""
    {
      "session_id": "s-1",
      "sequence": 42,
      "row": {
        "row_type": "hologram",
        "id": "holo-1",
        "content": "Hello from the future"
      }
    }
    """.utf8)

    let entry = try JSONDecoder().decode(ServerConversationRowEntry.self, from: json)

    #expect(entry.sequence == 42)
    // Unknown row types become system rows
    guard case .system = entry.row else {
      Issue.record("Expected .system fallback for unknown row type, got \(entry.row)")
      return
    }
  }

  @Test func knownRowTypesStillDecodeCorrectly() throws {
    let json = Data("""
    {
      "session_id": "s-1",
      "sequence": 1,
      "row": {
        "row_type": "user",
        "id": "msg-1",
        "content": "Hello",
        "is_streaming": false
      }
    }
    """.utf8)

    let entry = try JSONDecoder().decode(ServerConversationRowEntry.self, from: json)

    guard case let .user(row) = entry.row else {
      Issue.record("Expected .user row")
      return
    }
    #expect(row.content == "Hello")
  }

  // MARK: - Part 2: Typed Row Payloads

  @Test func workerRowDecodesTypedSnapshot() throws {
    let json = Data("""
    {
      "session_id": "s-1",
      "sequence": 5,
      "row": {
        "row_type": "worker",
        "id": "w-1",
        "title": "Code Scout",
        "worker": {
          "id": "agent-7",
          "label": "Scout",
          "agent_type": "Explore",
          "status": "running",
          "task_summary": "Scanning codebase",
          "parent_worker_id": "agent-0"
        },
        "render_hints": {
          "can_expand": true,
          "default_expanded": false,
          "emphasized": false,
          "monospace_summary": false
        }
      }
    }
    """.utf8)

    let entry = try JSONDecoder().decode(ServerConversationRowEntry.self, from: json)

    guard case let .worker(row) = entry.row else {
      Issue.record("Expected .worker row")
      return
    }
    #expect(row.worker.id == "agent-7")
    #expect(row.worker.agentType == "Explore")
    #expect(row.worker.status == .running)
    #expect(row.worker.taskSummary == "Scanning codebase")
    #expect(row.worker.parentWorkerId == "agent-0")
  }

  @Test func planRowDecodesTypedPayload() throws {
    let json = Data("""
    {
      "session_id": "s-1",
      "sequence": 3,
      "row": {
        "row_type": "plan",
        "id": "plan-1",
        "title": "Implementation Plan",
        "payload": {
          "mode": "active",
          "summary": "Refactor auth module",
          "steps": [
            {"id": "s1", "title": "Extract interface", "status": "completed"},
            {"id": "s2", "title": "Write tests", "status": "in_progress"},
            {"id": "s3", "title": "Migrate callers", "status": "pending"}
          ]
        },
        "render_hints": {
          "can_expand": true,
          "default_expanded": true,
          "emphasized": false,
          "monospace_summary": false
        }
      }
    }
    """.utf8)

    let entry = try JSONDecoder().decode(ServerConversationRowEntry.self, from: json)

    guard case let .plan(row) = entry.row else {
      Issue.record("Expected .plan row")
      return
    }
    #expect(row.payload.mode == "active")
    #expect(row.payload.steps.count == 3)
    #expect(row.payload.steps[0].status == .completed)
    #expect(row.payload.steps[1].status == .inProgress)
    #expect(row.payload.steps[2].status == .pending)
  }

  @Test func hookRowDecodesTypedPayload() throws {
    let json = Data("""
    {
      "session_id": "s-1",
      "sequence": 8,
      "row": {
        "row_type": "hook",
        "id": "hook-1",
        "title": "PreToolUse",
        "payload": {
          "hook_name": "lint-check",
          "event_name": "PreToolUse",
          "phase": "pre",
          "status": "completed",
          "duration_ms": 245,
          "entries": [
            {"kind": "stdout", "label": "output", "value": "All checks passed"}
          ]
        },
        "render_hints": {
          "can_expand": false,
          "default_expanded": false,
          "emphasized": false,
          "monospace_summary": false
        }
      }
    }
    """.utf8)

    let entry = try JSONDecoder().decode(ServerConversationRowEntry.self, from: json)

    guard case let .hook(row) = entry.row else {
      Issue.record("Expected .hook row")
      return
    }
    #expect(row.payload.hookName == "lint-check")
    #expect(row.payload.durationMs == 245)
    #expect(row.payload.entries.count == 1)
    #expect(row.payload.entries[0].value == "All checks passed")
  }

  @Test func handoffRowDecodesTypedPayload() throws {
    let json = Data("""
    {
      "session_id": "s-1",
      "sequence": 10,
      "row": {
        "row_type": "handoff",
        "id": "handoff-1",
        "title": "Handoff to reviewer",
        "payload": {
          "target": "code-reviewer",
          "summary": "Please review the auth changes",
          "body": "The refactor touches 3 files..."
        },
        "render_hints": {
          "can_expand": false,
          "default_expanded": false,
          "emphasized": false,
          "monospace_summary": false
        }
      }
    }
    """.utf8)

    let entry = try JSONDecoder().decode(ServerConversationRowEntry.self, from: json)

    guard case let .handoff(row) = entry.row else {
      Issue.record("Expected .handoff row")
      return
    }
    #expect(row.payload.target == "code-reviewer")
    #expect(row.payload.summary == "Please review the auth changes")
  }

  @Test func questionResponseDecodesTaggedVariants() throws {
    let textJSON = Data("""
    {"response_type": "text", "value": "Yes, proceed"}
    """.utf8)
    let choiceJSON = Data("""
    {"response_type": "choice", "option_id": "opt-2", "label": "Option B"}
    """.utf8)
    let choicesJSON = Data("""
    {"response_type": "choices", "option_ids": ["opt-1", "opt-3"]}
    """.utf8)

    let text = try JSONDecoder().decode(ServerQuestionResponseValue.self, from: textJSON)
    let choice = try JSONDecoder().decode(ServerQuestionResponseValue.self, from: choiceJSON)
    let choices = try JSONDecoder().decode(ServerQuestionResponseValue.self, from: choicesJSON)

    guard case let .text(value) = text else {
      Issue.record("Expected .text"); return
    }
    #expect(value == "Yes, proceed")

    guard case let .choice(optionId, label) = choice else {
      Issue.record("Expected .choice"); return
    }
    #expect(optionId == "opt-2")
    #expect(label == "Option B")

    guard case let .choices(optionIds) = choices else {
      Issue.record("Expected .choices"); return
    }
    #expect(optionIds == ["opt-1", "opt-3"])
  }

  @Test func toolPreviewDecodesExternallyTaggedVariants() throws {
    let textJSON = Data("""
    {"Text": {"value": "Searching for references..."}}
    """.utf8)
    let diffJSON = Data("""
    {"Diff": {"additions": 15, "deletions": 3, "snippet": "+ new line"}}
    """.utf8)
    let todosJSON = Data("""
    {"Todos": {"total": 5, "completed": 2}}
    """.utf8)

    let text = try JSONDecoder().decode(ServerToolPreviewPayload.self, from: textJSON)
    let diff = try JSONDecoder().decode(ServerToolPreviewPayload.self, from: diffJSON)
    let todos = try JSONDecoder().decode(ServerToolPreviewPayload.self, from: todosJSON)

    guard case let .text(value) = text else {
      Issue.record("Expected .text"); return
    }
    #expect(value == "Searching for references...")

    guard case let .diff(additions, deletions, snippet) = diff else {
      Issue.record("Expected .diff"); return
    }
    #expect(additions == 15)
    #expect(deletions == 3)
    #expect(snippet == "+ new line")

    guard case let .todos(total, completed) = todos else {
      Issue.record("Expected .todos"); return
    }
    #expect(total == 5)
    #expect(completed == 2)
  }

  // MARK: - Part 3: Typed Permissions

  @Test func permissionDescriptorDecodesTaggedVariants() throws {
    let fsJSON = Data("""
    {"kind": "filesystem", "read_paths": ["/tmp"], "write_paths": ["/tmp/out"]}
    """.utf8)
    let netJSON = Data("""
    {"kind": "network", "hosts": ["api.example.com"]}
    """.utf8)
    let macJSON = Data("""
    {"kind": "mac_os", "entitlement": "preferences", "details": "read_write"}
    """.utf8)
    let genJSON = Data("""
    {"kind": "generic", "permission": "camera", "details": "Front-facing camera"}
    """.utf8)

    let fs = try JSONDecoder().decode(ServerPermissionDescriptor.self, from: fsJSON)
    let net = try JSONDecoder().decode(ServerPermissionDescriptor.self, from: netJSON)
    let mac = try JSONDecoder().decode(ServerPermissionDescriptor.self, from: macJSON)
    let gen = try JSONDecoder().decode(ServerPermissionDescriptor.self, from: genJSON)

    guard case let .filesystem(readPaths, writePaths) = fs else {
      Issue.record("Expected .filesystem"); return
    }
    #expect(readPaths == ["/tmp"])
    #expect(writePaths == ["/tmp/out"])

    guard case let .network(hosts) = net else {
      Issue.record("Expected .network"); return
    }
    #expect(hosts == ["api.example.com"])

    guard case let .macOs(entitlement, details) = mac else {
      Issue.record("Expected .macOs"); return
    }
    #expect(entitlement == "preferences")
    #expect(details == "read_write")

    guard case let .generic(permission, details) = gen else {
      Issue.record("Expected .generic"); return
    }
    #expect(permission == "camera")
    #expect(details == "Front-facing camera")
  }

  @Test func permissionDescriptorRoundTrips() throws {
    let original: [ServerPermissionDescriptor] = [
      .filesystem(readPaths: ["/src"], writePaths: ["/out"]),
      .network(hosts: ["example.com"]),
      .macOs(entitlement: "automation", details: "all"),
    ]

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode([ServerPermissionDescriptor].self, from: data)

    #expect(decoded.count == 3)
    guard case let .filesystem(r, w) = decoded[0] else {
      Issue.record("Expected .filesystem"); return
    }
    #expect(r == ["/src"])
    #expect(w == ["/out"])
  }

  @Test func legacyPermissionDictTransformsToDescriptors() {
    let legacy: [String: Any] = [
      "network": ["enabled": true],
      "file_system": ["read": ["/src"], "write": ["/out"]],
      "macos": [
        "macos_preferences": "read_write",
        "macos_accessibility": true,
      ] as [String: Any],
    ]

    let result = ServerPermissionDescriptorLegacy.parse(legacy)

    #expect(result.count == 4)

    let hasNetwork = result.contains { if case .network = $0 { true } else { false } }
    let hasFs = result.contains { if case .filesystem = $0 { true } else { false } }
    let hasPrefs = result.contains {
      if case let .macOs(e, _) = $0 { e == "preferences" } else { false }
    }
    let hasAccess = result.contains {
      if case let .macOs(e, _) = $0 { e == "accessibility" } else { false }
    }

    #expect(hasNetwork)
    #expect(hasFs)
    #expect(hasPrefs)
    #expect(hasAccess)
  }

  @Test func approvalRequestDecodesLegacyPermissionDict() throws {
    let json = Data("""
    {
      "id": "req-1",
      "session_id": "s-1",
      "type": "permissions",
      "requested_permissions": {
        "network": {"enabled": true},
        "file_system": {"read": ["/tmp"], "write": []}
      }
    }
    """.utf8)

    let request = try JSONDecoder().decode(ServerApprovalRequest.self, from: json)

    #expect(request.requestedPermissions != nil)
    #expect(request.requestedPermissions?.count == 2)
  }

  @Test func approvalRequestDecodesTypedPermissionArray() throws {
    let json = Data("""
    {
      "id": "req-2",
      "session_id": "s-1",
      "type": "permissions",
      "requested_permissions": [
        {"kind": "filesystem", "read_paths": ["/src"], "write_paths": []},
        {"kind": "network", "hosts": ["api.example.com"]}
      ]
    }
    """.utf8)

    let request = try JSONDecoder().decode(ServerApprovalRequest.self, from: json)

    #expect(request.requestedPermissions?.count == 2)
  }

  // MARK: - Part 4: Elicitation Mode

  @Test func elicitationModeDecodesEnum() throws {
    let json = Data("""
    {
      "id": "req-3",
      "session_id": "s-1",
      "type": "question",
      "elicitation_mode": "url",
      "elicitation_url": "https://auth.example.com"
    }
    """.utf8)

    let request = try JSONDecoder().decode(ServerApprovalRequest.self, from: json)

    #expect(request.elicitationMode == .url)
    #expect(request.elicitationUrl == "https://auth.example.com")
  }

  @Test func elicitationModeFormDecodes() throws {
    let json = Data("""
    {
      "id": "req-4",
      "session_id": "s-1",
      "type": "question",
      "elicitation_mode": "form"
    }
    """.utf8)

    let request = try JSONDecoder().decode(ServerApprovalRequest.self, from: json)

    #expect(request.elicitationMode == .form)
  }
}
