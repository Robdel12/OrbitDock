import CoreGraphics
@testable import OrbitDock
import Testing

struct ExpandedToolCellPlanningTests {
  @Test func cardLayoutPlanShowsCancelableProgressChrome() {
    let accent = PlatformColor.calibrated(red: 0.3, green: 0.6, blue: 1.0, alpha: 1)
    let model = NativeExpandedToolModel(
      messageID: "msg-1",
      toolColor: accent,
      iconName: "terminal",
      hasError: false,
      isInProgress: true,
      canCancel: true,
      duration: "1.2s",
      linkedWorkerID: nil,
      content: .task(agentLabel: "Build", agentColor: accent, description: "Running", output: nil, isComplete: false)
    )

    let plan = ExpandedToolCellPlanning.cardLayoutPlan(for: model, width: 420)

    #expect(plan.progressFrame != nil)
    #expect(plan.cancelFrame != nil)
    #expect(plan.chevronFrame == nil)
    #expect(plan.durationFrame == nil)
    #expect(plan.contentContainerFrame.minY == plan.headerHeight)
  }

  @Test func payloadLabelPlanKeepsQuestionDetailIndented() {
    let row = ExpandedToolPayloadTextRowPlan(
      style: .questionDetail,
      content: .plain("Continue the current plan"),
      leadingInset: 14,
      widthAdjustment: 14,
      topInset: 2,
      bottomSpacing: 2
    )

    let plan = ExpandedToolCellPlanning.payloadLabelPlan(for: row, containerWidth: 360)

    #expect(plan.text == "Continue the current plan")
    #expect(plan.frame.origin.x == ExpandedToolLayout.headerHPad + 14)
    #expect(plan.frame.width == 360 - ExpandedToolLayout.headerHPad * 2 - 14)
    #expect(plan.frame.height > 0)
  }
}
