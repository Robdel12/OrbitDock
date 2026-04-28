import Foundation
@testable import OrbitDock
import Testing

@Suite(.serialized)
@MainActor
struct ServerSessionTransportReconnectRecoveryTests {
  @Test func subscribeUsesRecordedRevisionForInitialAndReconnectSubscriptions() async throws {
    let connection = EndpointRuntimeConnectionSpy()
    let harness = try makeSessionHarness(
      loader: { request in try await SimpleTransportFixture().loader(request) },
      connection: connection
    )
    let session = harness.session

    session.transport.recordRevision(13)
    session.transport.subscribe(surfaces: [.detail, .conversation])

    #expect(connection.subscribeCalls.count == 2)
    #expect(connection.subscribeCalls.allSatisfy { $0.sinceRevision == 13 })

    connection.clearSubscribeCalls()
    session.transport.handleConnectionStatusChanged(.connected)

    #expect(connection.subscribeCalls.count == 2)
    #expect(connection.subscribeCalls.allSatisfy { $0.sinceRevision == 13 })
  }

  @Test func sharedSurfaceSubscriptionsReferenceCountBeforeSocketUnsubscribe() async throws {
    let connection = EndpointRuntimeConnectionSpy()
    let harness = try makeSessionHarness(
      loader: { request in try await SimpleTransportFixture().loader(request) },
      connection: connection
    )
    let session = harness.session

    session.transport.subscribe(surfaces: [.capabilities])
    session.transport.subscribe(surfaces: [.capabilities])
    #expect(connection.subscribeCalls.count == 1)

    session.transport.unsubscribe(surfaces: [.capabilities])
    #expect(connection.unsubscribeCalls.isEmpty)

    session.transport.unsubscribe(surfaces: [.capabilities])
    #expect(connection.unsubscribeCalls.count == 1)
    #expect(connection.unsubscribeCalls.first?.surface == .capabilities)
  }

  @Test func conversationSurfaceInvalidationOnlySignalsConversationRefresh() async throws {
    let harness = try makeSessionHarness(
      loader: { request in try await SimpleTransportFixture().loader(request) },
      connection: EndpointRuntimeConnectionSpy()
    )
    let session = harness.session
    let (events, id) = session.transport.events()

    async let invalidationCounts = ConversationEventRecorder.collectInvalidationCounts(
      from: events,
      until: (ServerSessionInvalidation.conversation, 1)
    )
    session.transport.handleEvent(
      .sessionSurfaceInvalidated(
        sessionId: "session-1",
        surface: .conversation,
        revision: 19
      )
    )

    let counts = await invalidationCounts
    session.transport.removeEventListener(id: id)

    #expect(counts[.conversation, default: 0] == 1)
    #expect(counts[.detail, default: 0] == 0)
  }

  @Test func conversationViewModelRefreshBootstrapsFromHTTPAndRecordsRevision() async throws {
    let fixture = ConversationBootstrapFixture()
    let harness = try makeSessionHarness(
      loader: { request in try await fixture.loader(request) },
      connection: EndpointRuntimeConnectionSpy()
    )
    let session = harness.session
    let viewModel = ConversationViewModel(
      sessionId: "session-1",
      session: session,
      viewMode: .focused
    )

    await viewModel.refresh()
    session.transport.subscribe(surfaces: [.conversation])

    #expect(await fixture.conversationRequestCount == 1)
    #expect(viewModel.loadState == .ready)
    #expect(viewModel.hasTimeline)
    #expect(harness.connection.subscribeCalls.first?.sinceRevision == 13)
  }

  @Test func sessionContextRetainsEndpointRuntimeForConversationRefreshWithoutLeaking() async throws {
    let baseURL = try #require(URL(string: "http://127.0.0.1:4000"))
    let fixture = ConversationBootstrapFixture()
    var runtime: ServerEndpointRuntime? = ServerEndpointRuntime(
      clients: ServerClients(
        serverURL: baseURL,
        authToken: nil,
        dataLoader: { request in try await fixture.loader(request) }
      ),
      connection: EndpointRuntimeConnectionSpy(),
      endpointId: UUID()
    )
    weak var weakRuntime = runtime
    var session: ServerSessionContext? = runtime?.session("session-1")

    runtime = nil
    #expect(weakRuntime != nil)

    do {
      let viewModel = ConversationViewModel(
        sessionId: "session-1",
        session: try #require(session),
        viewMode: .focused
      )
      await viewModel.refresh()

      #expect(await fixture.conversationRequestCount == 1)
      #expect(viewModel.loadState == .ready)
    }

    session = nil
    await Task.yield()
    #expect(weakRuntime == nil)
    weakRuntime = nil
  }

  @Test func runtimeRoutesSocketRevisionEventsIntoSessionReplayCursor() async throws {
    let connection = EndpointRuntimeConnectionSpy()
    let harness = try makeSessionHarness(
      loader: { request in try await SimpleTransportFixture().loader(request) },
      connection: connection
    )

    harness.runtime.routeEvent(.revision(sessionId: "session-1", revision: 17))
    harness.session.transport.subscribe(surfaces: [.conversation])

    #expect(connection.subscribeCalls.count == 1)
    #expect(connection.subscribeCalls.first?.sinceRevision == 17)
  }

  @Test func backgroundSuspendPreservesSessionRealtimeLifecycleAcrossResume() async throws {
    let connection = EndpointRuntimeConnectionSpy()
    let harness = try makeSessionHarness(
      loader: { request in try await SimpleTransportFixture().loader(request) },
      connection: connection
    )
    let session = harness.session
    harness.runtime.startProcessingEvents()
    let (events, id) = session.transport.events()

    session.transport.subscribe(surfaces: [.detail])
    #expect(connection.subscribeCalls.count == 1)

    harness.runtime.suspendProcessingEventsForBackground()
    #expect(connection.unsubscribeCalls.isEmpty)

    connection.clearSubscribeCalls()
    async let invalidationCounts = ConversationEventRecorder.collectInvalidationCounts(
      from: events,
      until: (.detail, 1)
    )

    harness.runtime.startProcessingEvents()
    harness.runtime.routeEvent(.connectionStatusChanged(.connected))

    #expect(connection.subscribeCalls.count == 1)
    #expect(connection.subscribeCalls.first?.surface == .detail)

    harness.runtime.routeEvent(
      .sessionSurfaceInvalidated(
        sessionId: "session-1",
        surface: .detail,
        revision: 21
      )
    )

    let counts = await invalidationCounts
    session.transport.removeEventListener(id: id)

    #expect(counts[.detail, default: 0] == 1)
  }

  @Test func conversationRowDeltasDoNotTriggerAnotherBootstrapFetch() async throws {
    let fixture = ConversationBootstrapFixture()
    let harness = try makeSessionHarness(
      loader: { request in try await fixture.loader(request) },
      connection: EndpointRuntimeConnectionSpy()
    )
    let session = harness.session
    let viewModel = ConversationViewModel(
      sessionId: "session-1",
      session: session,
      viewMode: .focused
    )

    await viewModel.refresh()
    #expect(await fixture.conversationRequestCount == 1)

    viewModel.handleConversationRowDelta(
      .init(
        upserted: [
          makeUserRowEntry(
            sessionId: "session-1",
            rowId: "delta-row-1",
            sequence: 11,
            content: "delta update"
          )
        ],
        removedIds: []
      )
    )

    #expect(await fixture.conversationRequestCount == 1)
    #expect(viewModel.loadState == .ready)
    #expect(viewModel.hasTimeline)
    #expect(viewModel.latestAppendEvent?.count == 1)
  }

  @Test func localConversationMutationEmitsAcceptedRowAndConversationInvalidation() async throws {
    let fixture = ConversationMutationFixture()
    let harness = try makeSessionHarness(
      loader: { request in try await fixture.loader(request) },
      connection: EndpointRuntimeConnectionSpy()
    )
    let session = harness.session
    session.api.localNamingAvailabilityOverride = .unavailable
    let (events, id) = session.transport.events()

    async let captured = ConversationEventRecorder.collectRowAndConversationInvalidation(from: events)
    _ = try await session.api.sendMessage(content: "Ship it")
    let result = await captured
    session.transport.removeEventListener(id: id)

    #expect(result.rowIDs == ["send-row-1"])
    #expect(result.conversationInvalidationCount == 1)
    #expect(await fixture.sendMessageRequestCount == 1)
  }

  @Test func forcedResyncRequestsAreCoalescedAcrossInvalidationBursts() async throws {
    let fixture = ConversationBootstrapFixture()
    let harness = try makeSessionHarness(
      loader: { request in try await fixture.loader(request) },
      connection: EndpointRuntimeConnectionSpy()
    )
    let viewModel = ConversationViewModel(
      sessionId: "session-1",
      session: harness.session,
      viewMode: .focused
    )

    await viewModel.refresh()
    #expect(await fixture.conversationRequestCount == 1)

    viewModel.requestForcedResync(revision: 14)
    viewModel.requestForcedResync(revision: 14)
    viewModel.requestForcedResync(revision: 14)

    var attempts = 0
    while attempts < 200 {
      if await fixture.conversationRequestCount >= 2 {
        break
      }
      attempts += 1
      await Task.yield()
    }

    #expect(await fixture.conversationRequestCount == 2)

    // A second immediate invalidation burst should be ignored by cooldown.
    viewModel.requestForcedResync(revision: 14)
    viewModel.requestForcedResync(revision: 14)
    for _ in 0..<200 {
      await Task.yield()
    }
    #expect(await fixture.conversationRequestCount == 2)
  }

  @Test func forcedResyncIgnoresAlreadySyncedRevisionAndAllowsNewerRevision() async throws {
    let fixture = ConversationBootstrapFixture()
    let harness = try makeSessionHarness(
      loader: { request in try await fixture.loader(request) },
      connection: EndpointRuntimeConnectionSpy()
    )
    let viewModel = ConversationViewModel(
      sessionId: "session-1",
      session: harness.session,
      viewMode: .focused
    )

    await viewModel.refresh()
    #expect(await fixture.conversationRequestCount == 1)

    viewModel.requestForcedResync(revision: 13)
    for _ in 0..<200 {
      await Task.yield()
    }
    #expect(await fixture.conversationRequestCount == 1)

    viewModel.requestForcedResync(revision: 20)
    var attempts = 0
    while attempts < 200 {
      if await fixture.conversationRequestCount >= 2 {
        break
      }
      attempts += 1
      await Task.yield()
    }
    #expect(await fixture.conversationRequestCount == 2)
  }

  @Test func forcedResyncStillRunsAfterRecentConversationDelta() async throws {
    let fixture = ConversationBootstrapFixture()
    let harness = try makeSessionHarness(
      loader: { request in try await fixture.loader(request) },
      connection: EndpointRuntimeConnectionSpy()
    )
    let viewModel = ConversationViewModel(
      sessionId: "session-1",
      session: harness.session,
      viewMode: .focused
    )

    await viewModel.refresh()
    #expect(await fixture.conversationRequestCount == 1)

    viewModel.handleConversationRowDelta(
      .init(
        upserted: [
          makeUserRowEntry(
            sessionId: "session-1",
            rowId: "delta-row-2",
            sequence: 12,
            content: "delta update"
          )
        ],
        removedIds: []
      )
    )

    viewModel.requestForcedResync(revision: 20)
    var attempts = 0
    while attempts < 200 {
      if await fixture.conversationRequestCount >= 2 {
        break
      }
      attempts += 1
      await Task.yield()
    }

    #expect(await fixture.conversationRequestCount == 2)
  }

  @Test func forcedResyncKeepsApplyingLiveConversationRowsWhileHTTPRefreshIsRunning() async throws {
    let fixture = BlockingConversationResyncFixture()
    let harness = try makeSessionHarness(
      loader: { request in try await fixture.loader(request) },
      connection: EndpointRuntimeConnectionSpy()
    )
    let viewModel = ConversationViewModel(
      sessionId: "session-1",
      session: harness.session,
      viewMode: .focused
    )

    await viewModel.refresh()
    #expect(await fixture.conversationRequestCount == 1)

    viewModel.requestForcedResync(revision: 20)
    await fixture.waitForSecondConversationRequest()

    viewModel.handleConversationRowDelta(
      .init(
        upserted: [
          makeAssistantRowEntry(
            sessionId: "session-1",
            rowId: "delta-row-live",
            sequence: 11,
            content: "live row while refresh is running"
          )
        ],
        removedIds: []
      )
    )

    #expect(viewModel.loadState == .ready)
    #expect(viewModel.timelineViewModel.displayedEntryCount == 2)

    await fixture.releaseSecondConversationRequest()
  }

  @Test func unversionedForcedResyncBurstRunsOnceUntilRevisionAdvances() async throws {
    let fixture = ConversationBootstrapFixture()
    let harness = try makeSessionHarness(
      loader: { request in try await fixture.loader(request) },
      connection: EndpointRuntimeConnectionSpy()
    )
    let viewModel = ConversationViewModel(
      sessionId: "session-1",
      session: harness.session,
      viewMode: .focused
    )

    await viewModel.refresh()
    #expect(await fixture.conversationRequestCount == 1)

    viewModel.requestForcedResync(revision: nil)
    viewModel.requestForcedResync(revision: nil)
    viewModel.requestForcedResync(revision: nil)
    var attempts = 0
    while attempts < 200 {
      if await fixture.conversationRequestCount >= 2 {
        break
      }
      attempts += 1
      await Task.yield()
    }
    #expect(await fixture.conversationRequestCount == 2)

    viewModel.requestForcedResync(revision: nil)
    viewModel.requestForcedResync(revision: nil)
    for _ in 0..<200 {
      await Task.yield()
    }
    #expect(await fixture.conversationRequestCount == 2)

    viewModel.requestForcedResync(revision: 21)
    attempts = 0
    while attempts < 200 {
      if await fixture.conversationRequestCount >= 3 {
        break
      }
      attempts += 1
      await Task.yield()
    }
    #expect(await fixture.conversationRequestCount == 3)

    viewModel.requestForcedResync(revision: nil)
    attempts = 0
    while attempts < 200 {
      if await fixture.conversationRequestCount >= 4 {
        break
      }
      attempts += 1
      await Task.yield()
    }
    #expect(await fixture.conversationRequestCount == 4)
  }

  @Test func sessionDetailRefreshUsesLeanSnapshotWithoutDiffs() async throws {
    let fixture = SessionDetailRequestFixture()
    let harness = try makeSessionHarness(
      loader: { request in try await fixture.loader(request) },
      connection: EndpointRuntimeConnectionSpy()
    )
    let viewModel = SessionDetailViewModel(
      sessionId: "session-1",
      endpointId: harness.runtime.endpointId,
      session: harness.session
    )

    viewModel.bind(
      sessionId: "session-1",
      endpointId: harness.runtime.endpointId,
      session: harness.session
    )
    await viewModel.refresh()

    let detailRequest = await fixture.detailRequest
    #expect(detailRequest?.path == "/api/sessions/session-1/detail")
    #expect(detailRequest?.queryItems.isEmpty ?? true)
  }
}
