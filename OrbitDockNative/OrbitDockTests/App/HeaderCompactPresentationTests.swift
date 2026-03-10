import SwiftUI
import Testing
@testable import OrbitDock

struct HeaderCompactPresentationTests {
  @Test
  func effortLabelOmitsDefaultAndFormatsKnownValues() {
    #expect(HeaderCompactPresentation.effortLabel(for: nil) == nil)
    #expect(HeaderCompactPresentation.effortLabel(for: "default") == nil)
    #expect(HeaderCompactPresentation.effortLabel(for: " high ") == "High")
  }

  @Test
  func buildUsesProviderFallbackAndTruncatesLongModelSummary() {
    let presentation = HeaderCompactPresentation.build(
      workStatus: .waiting,
      provider: .claude,
      model: nil,
      effort: "max"
    )

    #expect(presentation.statusIcon == "clock.fill")
    #expect(presentation.statusLabel == "Waiting")
    #expect(presentation.modelSummary == "claude • Max")
  }

  @Test
  func buildTruncatesLongModelNamesDeterministically() {
    let presentation = HeaderCompactPresentation.build(
      workStatus: .permission,
      provider: .codex,
      model: "claude-3-7-sonnet-very-long-custom-model-name",
      effort: "medium"
    )

    #expect(presentation.statusIcon == "lock.fill")
    #expect(presentation.statusLabel == "Approval")
    #expect(presentation.modelSummary.hasSuffix("..."))
    #expect(presentation.modelSummary.count == 20)
  }
}
