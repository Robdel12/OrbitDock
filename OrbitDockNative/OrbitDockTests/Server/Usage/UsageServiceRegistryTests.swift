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

    #expect(service.codexRateLimitReachedType == .workspaceMemberUsageLimitReached)
    #expect(service.windows(for: .claude).count == 1)
    #expect(service.windows(for: .codex).count == 1)
    #expect(service.endpointSnapshots.count == 1)
    #expect(service.endpointSnapshots.first?.claudeWindows.count == 1)
    #expect(service.endpointSnapshots.first?.codexWindows.count == 1)
    #expect(service.providerBreakdown?.groups.map(\.groupKey) == ["codex"])
    #expect(service.modelBreakdown?.groups.map(\.groupKey) == ["GPT-5"])
    #expect(service.recentDayBreakdown?.groups.count == 1)
    #expect(service.topSessions?.sessions.first?.displayName == "OrbitDock API cleanup")
    #expect(await fixture.requestPaths() == [
      "/api/usage/overview",
      "/api/usage/sessions",
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
      "/api/usage/overview",
      "/api/usage/sessions",
      "/api/usage/claude",
      "/api/usage/codex",
      "/api/usage/overview",
      "/api/usage/sessions",
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
      case "/api/usage/overview":
        body = Data(
          """
          {
            "today_start_unix": 1713139200,
            "summary": {
              "today": {
                "session_count": 1,
                "distinct_session_count": 1,
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
                "distinct_session_count": 2,
                "total_tokens": 300,
                "input_tokens": 180,
                "output_tokens": 90,
                "cached_tokens": 30,
                "total_cost_usd": 3.75,
                "cost_by_model": [
                  { "model": "GPT-5", "cost_usd": 3.75 }
                ]
              }
            },
            "today_provider_breakdown": \(usageBreakdownJSON(groupBy: "provider")),
            "today_model_breakdown": \(usageBreakdownJSON(groupBy: "model")),
            "day_breakdown": \(usageBreakdownJSON(groupBy: "day"))
          }
          """.utf8
        )

      case "/api/usage/sessions":
        body = Data(
          """
          {
            "start_unix": 1713139200,
            "end_unix": null,
            "next_offset": null,
            "total_count": 1,
            "sessions": [
              {
                "session_id": "session-1",
                "provider": "codex",
                "display_name": "OrbitDock API cleanup",
                "project_name": "OrbitDock",
                "project_path": "/tmp/orbitdock-api-test",
                "model": "GPT-5",
                "started_at": "2026-04-15T09:00:00Z",
                "last_activity_at": "2026-04-15T09:30:00Z",
                "context_line": "Clean up the usage surface",
                "turn_count": 4,
                "input_tokens": 60,
                "output_tokens": 30,
                "cached_tokens": 10,
                "total_tokens": 100,
                "total_cost_usd": 1.25
              }
            ]
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
              "rate_limit_reached_type": "workspace_member_usage_limit_reached",
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

  private func usageBreakdownJSON(groupBy: String?) -> String {
    let group: String
    let provider: String
    let model: String
    let sessionId: String

    switch groupBy {
      case "provider":
        group = "codex"
        provider = #""codex""#
        model = "null"
        sessionId = "null"
      case "model":
        group = "GPT-5"
        provider = #""codex""#
        model = #""GPT-5""#
        sessionId = "null"
      case "session":
        group = "session-1"
        provider = #""codex""#
        model = #""GPT-5""#
        sessionId = #""session-1""#
      case "day":
        group = "1713139200"
        provider = "null"
        model = "null"
        sessionId = "null"
      default:
        group = groupBy ?? "unknown"
        provider = "null"
        model = "null"
        sessionId = "null"
    }

    return
      """
      {
        "group_by": "\(groupBy ?? "provider")",
        "start_unix": 1713139200,
        "end_unix": null,
        "totals": {
          "session_count": 1,
          "distinct_session_count": 1,
          "total_tokens": 100,
          "input_tokens": 60,
          "output_tokens": 30,
          "cached_tokens": 10,
          "total_cost_usd": 1.25,
          "cost_by_model": [
            { "model": "GPT-5", "cost_usd": 1.25 }
          ]
        },
        "groups": [
          {
            "group_key": "\(group)",
            "provider": \(provider),
            "model": \(model),
            "session_id": \(sessionId),
            "day_start_unix": \(groupBy == "day" ? "1713139200" : "null"),
            "turn_count": 4,
            "session_count": 1,
            "distinct_session_count": 1,
            "input_tokens": 60,
            "output_tokens": 30,
            "cached_tokens": 10,
            "total_tokens": 100,
            "total_cost_usd": 1.25
          }
        ]
      }
      """
  }
}
