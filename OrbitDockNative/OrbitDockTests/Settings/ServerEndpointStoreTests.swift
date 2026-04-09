import Foundation
@testable import OrbitDock
import Testing

struct ServerEndpointStoreTests {
  private final class InMemoryCloudSync {
    var endpoints: [ServerEndpointCloudRecord]?
  }

  @Test func startsEmptyWhenNoConfigExists() {
    let context = makeStoreContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let endpoints = context.store.endpoints()

    #expect(endpoints.isEmpty)
    #expect(context.store.hasRemoteEndpoint() == false)
  }

  @Test func defaultEndpointFallsBackToLoopbackAddress() {
    let context = makeStoreContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let fallback = context.store.defaultEndpoint()

    #expect(fallback.name == "Default Server")
    #expect(fallback.wsURL == URL(string: "ws://127.0.0.1:4000/ws"))
    #expect(fallback.isDefault)
  }

  @Test func replaceRemoteEndpointSetsRemoteAsDefault() {
    let context = makeStoreContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    context.store.replaceRemoteEndpoint(hostInput: "10.0.0.5:4100")

    let endpoints = context.store.endpoints()
    let remote = endpoints.first(where: \.isRemote)

    #expect(endpoints.count == 1)
    #expect(remote != nil)
    #expect(remote?.isDefault == true)
    #expect(remote?.wsURL == URL(string: "ws://10.0.0.5:4100/ws"))
    #expect(context.store.hasRemoteEndpoint())
  }

  @Test func clearRemoteEndpointsRemovesAllEndpoints() {
    let context = makeStoreContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    context.store.replaceRemoteEndpoint(hostInput: "192.168.1.99")
    context.store.clearRemoteEndpoints()

    let cleared = context.store.endpoints()

    #expect(context.store.remoteEndpoint() == nil)
    #expect(cleared.isEmpty)
  }

  @Test func crudSupportsUpsertDefaultEnableDisableAndRemove() throws {
    let context = makeStoreContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let remoteA = try ServerEndpoint(
      name: "Remote A",
      wsURL: #require(URL(string: "ws://10.0.0.1:4000/ws"))
    )
    var remoteB = try ServerEndpoint(
      name: "Remote B",
      wsURL: #require(URL(string: "ws://10.0.0.2:4000/ws"))
    )

    context.store.upsert(remoteA)
    context.store.upsert(remoteB)
    context.store.setDefaultEndpoint(id: remoteB.id)

    var endpoints = context.store.endpoints()
    #expect(endpoints.contains(where: { $0.id == remoteA.id }))
    #expect(endpoints.contains(where: { $0.id == remoteB.id }))
    #expect(endpoints.first(where: { $0.id == remoteB.id })?.isDefault == true)

    remoteB.name = "Remote B Updated"
    context.store.upsert(remoteB)
    endpoints = context.store.endpoints()
    #expect(endpoints.first(where: { $0.id == remoteB.id })?.name == "Remote B Updated")

    context.store.setEndpointEnabled(id: remoteB.id, isEnabled: false)
    let promotedDefault = context.store.defaultEndpoint()
    #expect(promotedDefault.id != remoteB.id)
    #expect(promotedDefault.isEnabled)

    context.store.remove(id: remoteA.id)
    let afterRemove = context.store.endpoints()
    #expect(afterRemove.contains(where: { $0.id == remoteA.id }) == false)
  }

  @Test func dedupesEndpointsWithEquivalentWsURLs() throws {
    let context = makeStoreContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let firstID = try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
    let secondID = try #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))

    let duplicateA = try ServerEndpoint(
      id: firstID,
      name: "Primary",
      wsURL: #require(URL(string: "wss://Dock.Example.com/ws")),
      isEnabled: true,
      isDefault: false
    )
    let duplicateB = try ServerEndpoint(
      id: secondID,
      name: "Preferred",
      wsURL: #require(URL(string: "wss://dock.example.com:443/ws/")),
      isEnabled: true,
      isDefault: true
    )

    context.store.save([duplicateA, duplicateB])
    let endpoints = context.store.endpoints()

    #expect(endpoints.count == 1)
    #expect(endpoints.first?.id == secondID)
    #expect(endpoints.first?.isDefault == true)
  }

  @Test func dedupesEndpointsWithSharedServerIdentityAcrossDifferentURLs() throws {
    let context = makeStoreContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let loopback = try ServerEndpoint(
      name: "Loopback",
      wsURL: #require(URL(string: "ws://127.0.0.1:4000/ws")),
      isEnabled: true,
      isDefault: true
    )
    let remote = try ServerEndpoint(
      name: "LAN",
      wsURL: #require(URL(string: "ws://192.168.0.230:4000/ws")),
      isEnabled: true,
      isDefault: false
    )

    context.store.save([loopback, remote])
    context.store.recordServerIdentity(id: loopback.id, serverInstanceId: "server-1")
    context.store.recordServerIdentity(id: remote.id, serverInstanceId: "server-1")

    let endpoints = context.store.endpoints()

    #expect(endpoints.count == 1)
    #expect(endpoints.first?.id == loopback.id)
    #expect(endpoints.first?.wsURL == loopback.wsURL)
    #expect(context.cloudSync.endpoints?.allSatisfy { $0.serverInstanceId == "server-1" } == true)
  }

  @Test func buildURLNormalizesHostInputs() {
    let plain = ServerEndpointStore.buildURL(fromHostInput: "10.0.0.8", defaultPort: 4_000)
    let withPath = ServerEndpointStore.buildURL(fromHostInput: "ws://10.0.0.9:4010/ws", defaultPort: 4_000)

    #expect(plain == URL(string: "ws://10.0.0.8:4000/ws"))
    #expect(withPath == URL(string: "ws://10.0.0.9:4010/ws"))
  }

  @Test func buildURLRejectsBindAddresses() {
    let ipv4Bind = ServerEndpointStore.buildURL(fromHostInput: "0.0.0.0:4000", defaultPort: 4_000)
    let ipv6Bind = ServerEndpointStore.buildURL(fromHostInput: "http://[::]:4000", defaultPort: 4_000)

    #expect(ipv4Bind == nil)
    #expect(ipv6Bind == nil)
  }

  @Test func hostInputOmitsDefaultPort() throws {
    let defaultPortURL = try #require(URL(string: "ws://10.0.0.8:4000/ws"))
    let customPortURL = try #require(URL(string: "ws://10.0.0.8:4111/ws"))

    #expect(ServerEndpointStore.hostInput(from: defaultPortURL, defaultPort: 4_000) == "10.0.0.8")
    #expect(ServerEndpointStore.hostInput(from: customPortURL, defaultPort: 4_000) == "10.0.0.8:4111")
  }

  @Test func appliesLocalPrefsToCloudSyncedEndpoints() throws {
    let context = makeStoreContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let endpointIdA = try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
    let endpointIdB = try #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))

    // Set up cloud records (synced from another device)
    context.cloudSync.endpoints = [
      try ServerEndpointCloudRecord(
        id: endpointIdA,
        name: "Cloud A",
        wsURL: #require(URL(string: "wss://dock-a.example/ws")),
        authToken: "token-a"
      ),
      try ServerEndpointCloudRecord(
        id: endpointIdB,
        name: "Cloud B",
        wsURL: #require(URL(string: "wss://dock-b.example/ws")),
        authToken: "token-b"
      ),
    ]

    // Set local prefs (device-specific enabled/default state)
    let localPrefs = [
      ServerEndpointLocalPrefs(id: endpointIdA, isEnabled: true, isDefault: true),
      ServerEndpointLocalPrefs(id: endpointIdB, isEnabled: false, isDefault: false),
    ]
    let prefsData = try JSONEncoder().encode(localPrefs)
    context.defaults.set(prefsData, forKey: context.localPrefsKey)

    let endpoints = context.store.endpoints()

    // Cloud data (name, url, token) comes from cloud
    #expect(endpoints.first(where: { $0.id == endpointIdA })?.name == "Cloud A")
    #expect(endpoints.first(where: { $0.id == endpointIdA })?.wsURL == URL(string: "wss://dock-a.example/ws"))
    #expect(endpoints.first(where: { $0.id == endpointIdA })?.authToken == "token-a")

    // Local prefs (enabled, default) come from local storage
    #expect(endpoints.first(where: { $0.id == endpointIdA })?.isEnabled == true)
    #expect(endpoints.first(where: { $0.id == endpointIdA })?.isDefault == true)
    #expect(endpoints.first(where: { $0.id == endpointIdB })?.isEnabled == false)
    #expect(endpoints.first(where: { $0.id == endpointIdB })?.isDefault == false)
  }

  @Test func saveWritesEndpointRecordsToCloudSync() throws {
    let context = makeStoreContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let endpoint = try ServerEndpoint(
      name: "Synced",
      wsURL: #require(URL(string: "wss://dock.example.com/ws")),
      isEnabled: true,
      isDefault: true,
      authToken: "secret-token"
    )

    context.store.save([endpoint])

    #expect(context.cloudSync.endpoints?.count == 1)
    #expect(context.cloudSync.endpoints?.first?.name == "Synced")
    #expect(context.cloudSync.endpoints?.first?.wsURL == endpoint.wsURL)
    #expect(context.cloudSync.endpoints?.first?.authToken == "secret-token")
  }

  @Test func enabledAndDefaultAreNotSyncedToCloud() throws {
    let context = makeStoreContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let endpoint = try ServerEndpoint(
      name: "Test",
      wsURL: #require(URL(string: "wss://dock.example.com/ws")),
      isEnabled: false,
      isDefault: true
    )

    context.store.save([endpoint])

    // Cloud record should NOT have isEnabled/isDefault
    let cloudRecord = context.cloudSync.endpoints?.first
    #expect(cloudRecord != nil)

    // Verify by encoding and checking the JSON doesn't contain these keys
    let encoder = JSONEncoder()
    let data = try encoder.encode(cloudRecord)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json?["isEnabled"] == nil)
    #expect(json?["isDefault"] == nil)
  }

  @Test func setEnabledOnlyUpdatesLocalPrefs() throws {
    let context = makeStoreContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let endpointId = try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
    context.cloudSync.endpoints = [
      try ServerEndpointCloudRecord(
        id: endpointId,
        name: "Test",
        wsURL: #require(URL(string: "wss://dock.example/ws"))
      ),
    ]

    // Record initial cloud state
    let initialCloudEndpoints = context.cloudSync.endpoints

    // Toggle enabled state
    context.store.setEndpointEnabled(id: endpointId, isEnabled: false)

    // Cloud should NOT have been modified
    #expect(context.cloudSync.endpoints == initialCloudEndpoints)

    // But local state should reflect the change
    let endpoints = context.store.endpoints()
    #expect(endpoints.first(where: { $0.id == endpointId })?.isEnabled == false)
  }

  @Test func setDefaultOnlyUpdatesLocalPrefs() throws {
    let context = makeStoreContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let endpointIdA = try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
    let endpointIdB = try #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
    context.cloudSync.endpoints = [
      try ServerEndpointCloudRecord(
        id: endpointIdA,
        name: "A",
        wsURL: #require(URL(string: "wss://a.example/ws"))
      ),
      try ServerEndpointCloudRecord(
        id: endpointIdB,
        name: "B",
        wsURL: #require(URL(string: "wss://b.example/ws"))
      ),
    ]

    // Record initial cloud state
    let initialCloudEndpoints = context.cloudSync.endpoints

    // Change default
    context.store.setDefaultEndpoint(id: endpointIdB)

    // Cloud should NOT have been modified
    #expect(context.cloudSync.endpoints == initialCloudEndpoints)

    // But local state should reflect the change
    let endpoints = context.store.endpoints()
    #expect(endpoints.first(where: { $0.id == endpointIdB })?.isDefault == true)
    #expect(endpoints.first(where: { $0.id == endpointIdA })?.isDefault == false)
  }

  @Test func skipsCloudWriteWhenDataUnchanged() throws {
    let context = makeStoreContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    var saveCount = 0
    let trackingCloudSync = InMemoryCloudSync()
    let trackingStore = ServerEndpointStore(
      defaults: context.defaults,
      endpointsKey: context.endpointsKey,
      endpointLocalPrefsKey: context.localPrefsKey,
      cloudSyncStore: ServerEndpointCloudSyncStore(
        load: { trackingCloudSync.endpoints },
        save: {
          saveCount += 1
          trackingCloudSync.endpoints = $0
        }
      ),
      defaultPort: 4_000
    )

    let endpoint = try ServerEndpoint(
      name: "Test",
      wsURL: #require(URL(string: "wss://dock.example.com/ws"))
    )

    // First save should write
    trackingStore.save([endpoint])
    #expect(saveCount == 1)

    // Second save with same data should skip cloud write
    trackingStore.save([endpoint])
    #expect(saveCount == 1) // Still 1, not 2
  }

  @Test func newEndpointDefaultsToEnabledWhenNoLocalPrefs() throws {
    let context = makeStoreContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let endpointId = try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))

    // Cloud has endpoint but no local prefs exist
    context.cloudSync.endpoints = [
      try ServerEndpointCloudRecord(
        id: endpointId,
        name: "New from Cloud",
        wsURL: #require(URL(string: "wss://dock.example/ws"))
      ),
    ]

    let endpoints = context.store.endpoints()

    // Should default to enabled
    #expect(endpoints.first?.isEnabled == true)
    // First endpoint should become default
    #expect(endpoints.first?.isDefault == true)
  }

  private func makeStoreContext() -> (
    store: ServerEndpointStore,
    defaults: UserDefaults,
    suiteName: String,
    endpointsKey: String,
    localPrefsKey: String,
    cloudSync: InMemoryCloudSync
  ) {
    let suiteName = "ServerEndpointStoreTests.\(UUID().uuidString)"
    let endpointsKey = "endpoints.\(UUID().uuidString)"
    let localPrefsKey = "local-prefs.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let cloudSync = InMemoryCloudSync()

    let store = ServerEndpointStore(
      defaults: defaults,
      endpointsKey: endpointsKey,
      endpointLocalPrefsKey: localPrefsKey,
      cloudSyncStore: ServerEndpointCloudSyncStore(
        load: { cloudSync.endpoints },
        save: { cloudSync.endpoints = $0 }
      ),
      defaultPort: 4_000
    )

    return (store, defaults, suiteName, endpointsKey, localPrefsKey, cloudSync)
  }
}
