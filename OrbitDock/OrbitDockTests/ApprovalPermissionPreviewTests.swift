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

  @Test func compactDetailTruncatesLongText() {
    let detail = ApprovalPermissionPreviewBuilder.compactPermissionDetail(
      serverDetail: "This is a very long detail that should be truncated at some point because it exceeds the limit",
      maxLength: 30
    )

    #expect(detail?.count == 30)
    #expect(detail?.hasSuffix("...") == true)
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
