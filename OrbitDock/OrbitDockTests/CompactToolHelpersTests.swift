@testable import OrbitDock
import Testing

struct CompactToolHelpersTests {
  @Test func compactSingleLineSummaryFlattensWhitespaceAndTruncates() {
    let value = "  first line  \n\n  second    line  "
    let summary = CompactToolHelpers.compactSingleLineSummary(value, maxLength: 10)
    #expect(summary == "first line...")
  }

  @Test func compactSingleLineSummaryReturnsToolWhenEmpty() {
    #expect(CompactToolHelpers.compactSingleLineSummary(" \n\t\r ") == "tool")
  }
}
