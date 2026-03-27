import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ServerSetupPlannerTests {
  @Test func loopbackHostDetectsAllVariants() {
    #expect(ServerSetupViewPlanner.isLoopbackHost("127.0.0.1"))
    #expect(ServerSetupViewPlanner.isLoopbackHost("localhost"))
    #expect(ServerSetupViewPlanner.isLoopbackHost("::1"))
    #expect(!ServerSetupViewPlanner.isLoopbackHost("10.0.0.5"))
    #expect(!ServerSetupViewPlanner.isLoopbackHost("orbitdock.example.com"))
  }

  @Test func buildEndpointRejectsLoopbackOnIOS() throws {
    // buildEndpoint has a #if os(iOS) guard that rejects loopback hosts.
    // On macOS this test verifies the loopback path succeeds instead.
    let result = ServerSetupViewPlanner.buildEndpoint(
      host: "127.0.0.1",
      authToken: "tok_test",
      existingEndpoints: [],
      defaultPort: 4_000,
      buildURL: { URL(string: "ws://\($0)") }
    )

    #if os(iOS)
      #expect(result == .failure(.loopbackNotReachableFromIOS))
    #else
      let endpoints = try result.get()
      #expect(endpoints.count == 1)
    #endif
  }

  @Test func buildEndpointNamesLoopbackServersClearly() throws {
    let result = ServerSetupViewPlanner.buildEndpoint(
      host: "127.0.0.1",
      authToken: "tok_test",
      existingEndpoints: [],
      defaultPort: 4_000,
      buildURL: { URL(string: "ws://\($0):4000/ws") }
    )

    let endpoints = try result.get()
    #expect(endpoints.count == 1)
    #expect(endpoints[0].name == "Loopback Server")
    #expect(endpoints[0].isDefault)
  }

  @Test func buildEndpointRequiresToken() {
    let result = ServerSetupViewPlanner.buildEndpoint(
      host: "10.0.0.5:4000",
      authToken: "",
      existingEndpoints: [],
      defaultPort: 4_000,
      buildURL: { URL(string: "ws://\($0)") }
    )

    #expect(result == .failure(ServerSetupConnectError.missingToken))
  }
}

@MainActor
struct ServerSetupVisibilityTests {
  @Test func showsSetupWhenNoEndpointsConfigured() {
    let shouldShow = AppWindowPlanner.shouldShowSetup(
      connectedRuntimeCount: 0,
      hasEndpoints: false
    )

    #expect(shouldShow)
  }

  @Test func hidesSetupWhenAnyRuntimeIsConnected() {
    let shouldShow = AppWindowPlanner.shouldShowSetup(
      connectedRuntimeCount: 1,
      hasEndpoints: true
    )

    #expect(!shouldShow)
  }

  @Test func hidesSetupWhenEndpointsExistButDisconnected() {
    let shouldShow = AppWindowPlanner.shouldShowSetup(
      connectedRuntimeCount: 0,
      hasEndpoints: true
    )

    #expect(!shouldShow)
  }
}
