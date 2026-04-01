import Foundation
@testable import OrbitDock
import Testing

struct ServerEndpointStoreTests {
  private final class InMemoryCloudSync {
    var endpoints: [ServerEndpoint]?
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

  @Test func prefersCloudSyncedEndpointsOverLocalDefaults() throws {
    let context = makeStoreContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let local = try ServerEndpoint(
      name: "Local",
      wsURL: #require(URL(string: "ws://10.0.0.10:4000/ws"))
    )
    let cloud = try ServerEndpoint(
      name: "Cloud",
      wsURL: #require(URL(string: "wss://dock.example.com/ws")),
      isDefault: true
    )

    context.defaults.set(try JSONEncoder().encode([local]), forKey: context.endpointsKey)
    context.cloudSync.endpoints = [cloud]

    let endpoints = context.store.endpoints()

    #expect(endpoints.count == 1)
    #expect(endpoints.first?.name == "Cloud")
  }

  @Test func saveWritesRedactedEndpointsToCloudSync() throws {
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
    #expect(context.cloudSync.endpoints?.first?.authToken == nil)
  }

  private func makeStoreContext() -> (
    store: ServerEndpointStore,
    defaults: UserDefaults,
    suiteName: String,
    endpointsKey: String,
    cloudSync: InMemoryCloudSync
  ) {
    let suiteName = "ServerEndpointStoreTests.\(UUID().uuidString)"
    let endpointsKey = "endpoints.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let cloudSync = InMemoryCloudSync()

    let store = ServerEndpointStore(
      defaults: defaults,
      endpointsKey: endpointsKey,
      cloudSyncStore: ServerEndpointCloudSyncStore(
        load: { cloudSync.endpoints },
        save: { cloudSync.endpoints = $0 }
      ),
      defaultPort: 4_000
    )

    return (store, defaults, suiteName, endpointsKey, cloudSync)
  }
}
