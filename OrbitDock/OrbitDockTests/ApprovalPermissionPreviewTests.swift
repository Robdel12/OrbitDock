@testable import OrbitDock
import Testing

struct ApprovalPermissionPreviewTests {

  @Test func hasPreviewContentWithShellSegments() {
    let segments = [
      ApprovalShellSegment(
        command: #"sqlite3 ~/.orbitdock/orbitdock.db "SELECT * FROM claude_models;" 2>/dev/null"#,
        leadingOperator: nil
      ),
      ApprovalShellSegment(command: #"echo "Table empty or doesn't exist""#, leadingOperator: "||"),
    ]
    let model = makeModel(
      previewType: .shellCommand,
      command: nil,
      shellSegments: segments
    )

    #expect(ApprovalPermissionPreviewHelpers.hasPreviewContent(model) == true)
    #expect(ApprovalPermissionPreviewHelpers.showsProjectPath(model) == true)
  }

  @Test func hasPreviewContentWithCommandFallback() {
    let model = makeModel(
      previewType: .shellCommand,
      command: "echo hello"
    )

    #expect(ApprovalPermissionPreviewHelpers.hasPreviewContent(model) == true)
  }

  @Test func hasPreviewContentForFilePath() {
    let model = makeModel(
      previewType: .filePath,
      command: nil,
      filePath: "/tmp/OrbitDock/README.md",
      toolName: "Edit"
    )

    #expect(ApprovalPermissionPreviewHelpers.hasPreviewContent(model) == true)
    #expect(ApprovalPermissionPreviewHelpers.showsProjectPath(model) == false)
    #expect(ApprovalPermissionPreviewHelpers.previewIconName(for: model) == "pencil")
  }

  @Test func hasPreviewContentIsFalseWhenEmpty() {
    let model = makeModel(
      previewType: .action,
      command: nil
    )

    #expect(ApprovalPermissionPreviewHelpers.hasPreviewContent(model) == false)
  }

  @Test func operatorLabelMapsCorrectly() {
    #expect(ApprovalPermissionPreviewHelpers.operatorLabel("||") == "if previous fails")
    #expect(ApprovalPermissionPreviewHelpers.operatorLabel("&&") == "then")
    #expect(ApprovalPermissionPreviewHelpers.operatorLabel("|") == "pipe")
    #expect(ApprovalPermissionPreviewHelpers.operatorLabel(nil) == nil)
    #expect(ApprovalPermissionPreviewHelpers.operatorLabel("") == nil)
  }

  @Test func previewValueResolvesFilePathForFilePreviewType() {
    let model = makeModel(
      previewType: .filePath,
      command: "some command",
      filePath: "/tmp/file.swift"
    )

    #expect(ApprovalPermissionPreviewHelpers.previewValue(for: model) == "/tmp/file.swift")
  }

  @Test func previewValueResolvesCommandForShellType() {
    let model = makeModel(
      previewType: .shellCommand,
      command: "echo hello"
    )

    #expect(ApprovalPermissionPreviewHelpers.previewValue(for: model) == "echo hello")
  }

  @Test func shellSegmentDisplayLinesShowsOperatorsInOrder() {
    let model = makeModel(
      previewType: .shellCommand,
      command: nil,
      shellSegments: [
        ApprovalShellSegment(command: "npm test", leadingOperator: nil),
        ApprovalShellSegment(command: "npm run lint", leadingOperator: "&&"),
      ]
    )

    let lines = ApprovalPermissionPreviewHelpers.shellSegmentDisplayLines(for: model)

    #expect(lines == [
      "1. npm test",
      "2. [&&] npm run lint",
    ])
  }

  @Test func shellSegmentDisplayLinesFallsBackToCommandWhenNoSegments() {
    let model = makeModel(
      previewType: .shellCommand,
      command: "git status"
    )

    let lines = ApprovalPermissionPreviewHelpers.shellSegmentDisplayLines(for: model)

    #expect(lines == ["1. git status"])
  }

  @Test func shellSegmentDisplayLinesEmptyForNonShellPreviewType() {
    let model = makeModel(
      previewType: .filePath,
      command: nil,
      filePath: "/tmp/OrbitDock/README.md"
    )

    let lines = ApprovalPermissionPreviewHelpers.shellSegmentDisplayLines(for: model)

    #expect(lines.isEmpty)
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
      amendmentDetail: nil,
      approvalType: .exec,
      projectPath: "/tmp/OrbitDock",
      approvalId: "req-preview",
      sessionId: "session-preview"
    )
  }
}
