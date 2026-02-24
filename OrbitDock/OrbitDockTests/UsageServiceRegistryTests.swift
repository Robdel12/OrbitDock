@testable import OrbitDock
import Testing

struct UsageServiceRegistryTests {
  @Test func shouldShowProviderWhenUsageExists() {
    #expect(
      UsageServiceRegistry.shouldShowProvider(
        hasUsage: true,
        isLoading: false,
        hasError: false
      )
    )
  }

  @Test func shouldShowProviderWhenLoading() {
    #expect(
      UsageServiceRegistry.shouldShowProvider(
        hasUsage: false,
        isLoading: true,
        hasError: false
      )
    )
  }

  @Test func shouldShowProviderWhenErrorExists() {
    #expect(
      UsageServiceRegistry.shouldShowProvider(
        hasUsage: false,
        isLoading: false,
        hasError: true
      )
    )
  }

  @Test func shouldShowProviderWhenCodexApiKeyMode() {
    #expect(
      UsageServiceRegistry.shouldShowProvider(
        hasUsage: false,
        isLoading: false,
        hasError: false,
        isApiKeyMode: true
      )
    )
  }

  @Test func shouldHideProviderWithoutUsageLoadingOrErrors() {
    #expect(
      !UsageServiceRegistry.shouldShowProvider(
        hasUsage: false,
        isLoading: false,
        hasError: false
      )
    )
  }
}
