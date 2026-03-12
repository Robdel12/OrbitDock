import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct RootShellRuntimeLoadTests {
  @Test func bootstrapHandlesTwoHundredPassiveSessionsWithRootSafeStateOnly() async throws {
    let runtime = makeRuntime(seedSessions: RootShellLoadFixture.passiveSessions(count: 200))

    let firstUpdate = Task { () -> RootShellRuntimeUpdate? in
      for await update in runtime.rootShellRuntime.updates {
        return update
      }
      return nil
    }

    runtime.rootShellRuntime.start()

    let update = try #require(await firstUpdate.value)
    #expect(update.upsertedSessions.count == 200)
    #expect(runtime.rootShellRuntime.rootShellStore.records().count == 200)
    #expect(runtime.rootShellRuntime.rootShellStore.counts.total == 200)
    #expect(runtime.rootShellRuntime.rootShellStore.counts.active == 200)
    #expect(runtime.sessionStore._sessionObservables.isEmpty)
    #expect(runtime.sessionStore.hotDetailSessions.isEmpty)
  }

  @Test func burstPassiveUpdatesConvergeOnLatestRootSummaryState() async throws {
    let store = RootShellStore()
    let endpointId = RootShellLoadFixture.endpointID
    let sessions = RootShellLoadFixture.passiveSessions(count: 120)

    #expect(
      store.apply(
        .sessionsList(
          endpointId: endpointId,
          endpointName: RootShellLoadFixture.endpointName,
          connectionStatus: .connected,
          sessions: sessions
        )
      )
    )

    let events = RootShellLoadFixture.updatedPassiveSessions(count: 100).map { session in
      RootShellEvent.sessionUpdated(
        endpointId: endpointId,
        endpointName: RootShellLoadFixture.endpointName,
        connectionStatus: .connected,
        session: session
      )
    }

    for event in RootShellEventCoalescer.coalesce(events) {
      _ = store.apply(event)
    }

    let updated = try #require(
      store.record(
        for: ScopedSessionID(endpointId: endpointId, sessionId: "passive-40").scopedID
      )
    )

    #expect(updated.workStatus == .working)
    #expect(updated.unreadCount == 2)
    #expect(updated.totalTokens == 2_040)
    #expect(updated.contextLine == "Updated context 40")
    #expect(store.records().count == 120)
  }

  @Test func detailOnlyTrafficDoesNotMutateRootShellRecords() async throws {
    let sessions = RootShellLoadFixture.passiveSessions(count: 25)
    let runtime = makeRuntime(seedSessions: sessions)

    let bootstrap = Task { () -> RootShellRuntimeUpdate? in
      for await update in runtime.rootShellRuntime.updates {
        return update
      }
      return nil
    }

    runtime.rootShellRuntime.start()
    _ = try #require(await bootstrap.value)

    let before = runtime.rootShellRuntime.rootShellStore.records()

    runtime.eventStream.emitForTesting(.revision(sessionId: "passive-0", revision: 7))
    await Task.yield()
    await Task.yield()

    let after = runtime.rootShellRuntime.rootShellStore.records()
    #expect(after == before)
    #expect(runtime.sessionStore._sessionObservables.isEmpty)
    #expect(runtime.sessionStore.hotDetailSessions.isEmpty)
  }

  private func makeRuntime(seedSessions: [ServerSessionListItem]) -> (
    endpoint: ServerEndpoint,
    eventStream: EventStream,
    sessionStore: SessionStore,
    rootShellRuntime: RootShellRuntime
  ) {
    let endpoint = ServerEndpoint(
      id: RootShellLoadFixture.endpointID,
      name: RootShellLoadFixture.endpointName,
      wsURL: URL(string: "ws://127.0.0.1:4000/ws")!,
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
    let clients = ServerClients(serverURL: URL(string: "http://127.0.0.1:4000")!, authToken: nil)
    let eventStream = EventStream(authToken: nil)
    eventStream.seedSessionsListForTesting(seedSessions)

    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [endpoint] },
      runtimeFactory: { _ in
        ServerRuntime(
          endpoint: endpoint,
          clients: clients,
          eventStream: eventStream
        )
      },
      shouldBootstrapFromSettings: false
    )
    registry.configureFromSettings(startEnabled: false)

    return (
      endpoint,
      eventStream,
      registry.sessionStore(for: endpoint.id, fallback: registry.activeSessionStore),
      RootShellRuntime(runtimeRegistry: registry)
    )
  }
}
