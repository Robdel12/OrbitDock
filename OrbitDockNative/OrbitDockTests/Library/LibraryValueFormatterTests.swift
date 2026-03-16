@testable import OrbitDock
import Testing

struct LibraryValueFormatterTests {
  @Test func formatsCostAcrossDisplayThresholds() {
    #expect(LibraryValueFormatter.cost(3.456) == "$3.46")
    #expect(LibraryValueFormatter.cost(12.34) == "$12.3")
    #expect(LibraryValueFormatter.cost(125.0) == "$125")
  }

  @Test func formatsTokenCountsAcrossMagnitudeThresholds() {
    #expect(LibraryValueFormatter.tokens(950) == "950")
    #expect(LibraryValueFormatter.tokens(12_300) == "12.3k")
    #expect(LibraryValueFormatter.tokens(2_400_000) == "2.4M")
  }
}
