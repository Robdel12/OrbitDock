import Foundation
@testable import OrbitDock
import Testing

@Suite(.serialized)
@MainActor
struct UsageServiceRegistryTests {
  @Test func refreshIfNeededReusesWarmUsageSnapshot() async throws {
    let fixture = UsageLoaderFixture()
    let registry = makeHarness(loader: fixture.loader)
    let service = UsageServiceRegistry(runtimeRegistry: registry)

    await service.refreshIfNeeded()
    await service.refreshIfNeeded()

    #expect(await fixture.requestPaths() == [
      "/api/usage/summary",
      "/api/usage/claude",
      "/api/usage/codex",
    ])
  }

  @Test func refreshAllBypassesWarmUsageSnapshotCache() async throws {
    let fixture = UsageLoaderFixture()
    let registry = makeHarness(loader: fixture.loader)
    let service = UsageServiceRegistry(runtimeRegistry: registry)

    await service.refreshIfNeeded()
    await service.refreshAll()

    #expect(await fixture.requestPaths() == [
      "/api/usage/summary",
      "/api/usage/claude",
      "/api/usage/codex",
      "/api/usage/summary",
      "/api/usage/claude",
      "/api/usage/codex",
    ])
  }

  private func makeHarness(
    loader: @escaping ServerClients.DataLoader
  ) -> ServerRuntimeRegistry {
    let endpoint = ServerEndpoint(
      name: "Primary",
      wsURL: URL(string: "ws://127.0.0.1:3000/ws")!
    )
    let connection = ServerConnection(authToken: nil)
    let clients = ServerClients(
      serverURL: URL(string: "http://127.0.0.1:3000")!,
      authToken: nil,
      dataLoader: loader
    )
    let runtime = ServerRuntime(
      endpoint: endpoint,
      clients: clients,
      connection: connection
    )
    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [endpoint] },
      runtimeFactory: { _ in runtime },
      shouldBootstrapFromSettings: false
    )
    registry.configureFromSettings(startEnabled: false)
    return registry
  }
}

private actor UsageLoaderFixture {
  private var paths: [String] = []

  func loader(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let url = try #require(request.url)
    paths.append(url.path)

    let body: Data
    switch url.path {
      case "/api/usage/summary":
        body = Data(
          """
          {
            "today": {
              "session_count": 1,
              "total_tokens": 100,
              "input_tokens": 60,
              "output_tokens": 30,
              "cached_tokens": 10,
              "total_cost_usd": 1.25,
              "cost_by_model": [
                { "model": "GPT-5", "cost_usd": 1.25 }
              ]
            },
            "all_time": {
              "session_count": 2,
              "total_tokens": 300,
              "input_tokens": 180,
              "output_tokens": 90,
              "cached_tokens": 30,
              "total_cost_usd": 3.75,
              "cost_by_model": [
                { "model": "GPT-5", "cost_usd": 3.75 }
              ]
            }
          }
          """.utf8
        )

      case "/api/usage/claude":
        body = Data(
          """
          {
            "usage": {
              "five_hour": {
                "utilization": 42.0,
                "resets_at": "2026-04-15T12:00:00Z"
              },
              "seven_day": null,
              "seven_day_sonnet": null,
              "seven_day_opus": null,
              "rate_limit_tier": null,
              "fetched_at_unix": 1713200000
            },
            "error_info": null
          }
          """.utf8
        )

      case "/api/usage/codex":
        body = Data(
          """
          {
            "usage": {
              "primary": {
                "used_percent": 18.0,
                "window_duration_mins": 60,
                "resets_at_unix": 1713203600
              },
              "secondary": null,
              "fetched_at_unix": 1713200000
            },
            "error_info": null
          }
          """.utf8
        )

      default:
        throw URLError(.badURL)
    }

    let response = HTTPURLResponse(
      url: url,
      statusCode: 200,
      httpVersion: nil,
      headerFields: [
        "Content-Type": "application/json",
        "X-OrbitDock-Server-Version": "0.9.0",
        "X-OrbitDock-Minimum-Client-Version": "0.4.0",
      ]
    )!
    return (body, response)
  }

  func requestPaths() -> [String] {
    paths
  }
}
