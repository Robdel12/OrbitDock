import Foundation
import Testing
@testable import OrbitDock

struct ModelPricingServiceTests {
  @Test func fetchPricesUsesInjectedLoaderAndUpdatesOnlyThatInstance() throws {
    let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cacheRoot) }

    let customModel = "claude-test"
    let remoteData = try JSONEncoder().encode([
      customModel: ModelPrice(
        inputCostPerToken: 1.0 / 1_000_000,
        outputCostPerToken: 2.0 / 1_000_000,
        cacheReadInputTokenCost: nil,
        cacheCreationInputTokenCost: nil
      ),
    ])

    let injectedService = ModelPricingService(
      cacheURL: cacheRoot.appendingPathComponent("pricing.json"),
      loadRemoteData: { _ in remoteData },
      runAsync: { work in work() }
    )
    let untouchedService = ModelPricingService(
      cacheURL: cacheRoot.appendingPathComponent("untouched.json"),
      runAsync: { work in work() }
    )

    injectedService.fetchPrices()

    #expect(injectedService.price(for: customModel) != nil)
    #expect(untouchedService.price(for: customModel) == nil)
    #expect(injectedService.isLoading == false)
  }
}
