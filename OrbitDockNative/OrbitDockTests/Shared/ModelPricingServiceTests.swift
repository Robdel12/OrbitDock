import Foundation
@testable import OrbitDock
import Testing

struct ModelPricingServiceTests {
  @Test func defaultPricesAreAvailableWithoutRemoteFetch() throws {
    let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cacheRoot) }

    let service = ModelPricingService(
      cacheURL: cacheRoot.appendingPathComponent("pricing.json")
    )

    #expect(service.price(for: "claude-sonnet-4") != nil)
    #expect(service.price(for: "claude-opus-4") != nil)
    #expect(service.isLoading == false)
  }
}
