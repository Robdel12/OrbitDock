@testable import OrbitDock
import Testing

struct ApprovalPermissionPreviewTests {

  @Test func structuredPreviewIsPreferredWhenManifestAndMetadataExist() {
    let segments = [
      ApprovalShellSegment(
        command: #"sqlite3 ~/.orbitdock/orbitdock.db "SELECT * FROM claude_models;" 2>/dev/null"#,
        leadingOperator: nil
      ),
      ApprovalShellSegment(command: #"echo "Table empty or doesn't exist""#, leadingOperator: "||"),
    ]
    let manifest = """
    APPROVAL MANIFEST
    request_id: req-preview
    approval_type: exec
    tool: Bash
    risk_tier: normal

    decision_scope: approve/deny applies to all command segments in this request.
    command_segments: 2
    segments:
    [1] sqlite3 ~/.orbitdock/orbitdock.db "SELECT * FROM claude_models;" 2>/dev/null
    [2] (||, if previous fails) echo "Table empty or doesn't exist"
    """
    let model = makeModel(
      previewType: .shellCommand,
      command: #"sqlite3 ~/.orbitdock/orbitdock.db "SELECT * FROM claude_models;" 2>/dev/null || echo "Table empty or doesn't exist""#,
      shellSegments: segments,
      serverManifest: manifest,
      decisionScope: "approve/deny applies to all command segments in this request."
    )

    let preview = ApprovalPermissionPreviewBuilder.build(for: model)

    #expect(preview?.showsProjectPath == true)
    #expect(preview?.text.contains("APPROVAL REQUEST") == true)
    #expect(preview?.text.contains("request_id: req-preview") == true)
    #expect(preview?.text
      .contains("decision_scope: approve/deny applies to all command segments in this request.") == true)
    #expect(preview?.text.contains("[2] (||, if previous fails) echo \"Table empty or doesn't exist\"") == true)
  }

  @Test func serverMetadataPreviewIncludesDecisionScopeAndSegmentOperators() {
    let segments = [
      ApprovalShellSegment(command: "echo one", leadingOperator: nil),
      ApprovalShellSegment(command: "echo two", leadingOperator: "||"),
    ]
    let model = makeModel(
      previewType: .shellCommand,
      command: "echo one || echo two",
      shellSegments: segments,
      decisionScope: "approve/deny applies to all command segments in this request."
    )

    let preview = ApprovalPermissionPreviewBuilder.build(for: model)

    #expect(preview?.showsProjectPath == true)
    #expect(preview?.text.contains("APPROVAL REQUEST") == true)
    #expect(preview?.text.contains("request_id: req-preview") == true)
    #expect(preview?.text
      .contains("decision_scope: approve/deny applies to all command segments in this request.") == true)
    #expect(preview?.text.contains("[2] (||, if previous fails) echo two") == true)
  }

  @Test func filePathPreviewUsesFileLabelAndNoProjectPathRow() {
    let model = makeModel(
      previewType: .filePath,
      command: nil,
      filePath: "/tmp/OrbitDock/README.md",
      toolName: "Edit",
      decisionScope: "approve/deny applies only to this file path request."
    )

    let preview = ApprovalPermissionPreviewBuilder.build(for: model)

    #expect(preview?.showsProjectPath == false)
    #expect(preview?.projectPathIconName == "pencil")
    #expect(preview?.text.contains("APPROVAL REQUEST") == true)
    #expect(preview?.text.contains("target_file: /tmp/OrbitDock/README.md") == true)
  }

  @Test func previewBuildsWithDefaultScopeWhenDecisionScopeMissing() {
    let model = makeModel(
      previewType: .shellCommand,
      command: "echo one"
    )

    let preview = ApprovalPermissionPreviewBuilder.build(for: model)

    #expect(preview?.text.contains("APPROVAL REQUEST") == true)
    #expect(preview?.text.contains("decision_scope: approve/deny applies to the full request payload.") == true)
  }

  @Test func compactDetailUsesServerDetailWhenProvided() {
    let detail = ApprovalPermissionPreviewBuilder.compactPermissionDetail(
      serverDetail: "sqlite3 ~/.orbitdock/orbitdock.db +1 segment",
      maxLength: 120
    )

    #expect(detail == "sqlite3 ~/.orbitdock/orbitdock.db +1 segment")
  }

  @Test func compactDetailIsNilWithoutServerDetail() {
    let detail = ApprovalPermissionPreviewBuilder.compactPermissionDetail(
      serverDetail: nil,
      maxLength: 120
    )

    #expect(detail == nil)
  }

  private func makeModel(
    previewType: ApprovalPreviewType,
    command: String?,
    filePath: String? = nil,
    toolName: String? = "Bash",
    shellSegments: [ApprovalShellSegment] = [],
    serverManifest: String? = nil,
    decisionScope: String? = nil,
    risk: ApprovalRisk = .normal,
    riskFindings: [String] = []
  ) -> ApprovalCardModel {
    ApprovalCardModel(
      mode: .permission,
      toolName: toolName,
      previewType: previewType,
      shellSegments: shellSegments,
      serverManifest: serverManifest,
      decisionScope: decisionScope,
      command: command,
      filePath: filePath,
      risk: risk,
      riskFindings: riskFindings,
      diff: nil,
      questions: [],
      hasAmendment: false,
      approvalType: .exec,
      projectPath: "/tmp/OrbitDock",
      approvalId: "req-preview",
      sessionId: "session-preview"
    )
  }
}
