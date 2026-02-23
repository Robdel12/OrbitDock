import Foundation
@testable import OrbitDock
import Testing

struct ServerEndpointStoreTests {
  @Test func seedsLocalEndpointWhenNoConfigExists() {
    let context = makeStoreContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let endpoints = context.store.endpoints()

    #expect(endpoints.count == 1)
    #expect(endpoints[0].isLocalManaged)
    #expect(endpoints[0].isEnabled)
    #expect(endpoints[0].isDefault)
    #expect(endpoints[0].wsURL == URL(string: "ws://127.0.0.1:4000/ws"))
    #expect(context.store.effectiveURL() == URL(string: "ws://127.0.0.1:4000/ws"))
  }

  @Test func migratesLegacyRemoteHostIntoEndpointList() {
    let context = makeStoreContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    context.defaults.set("10.0.0.5:4100", forKey: context.legacyRemoteHostKey)

    let endpoints = context.store.endpoints()
    let remote = endpoints.first(where: \.isRemote)

    #expect(endpoints.count == 2)
    #expect(remote != nil)
    #expect(remote?.isDefault == true)
    #expect(remote?.wsURL == URL(string: "ws://10.0.0.5:4100/ws"))
    #expect(context.defaults.data(forKey: context.endpointsKey) != nil)
  }

  @Test func legacyRemoteHostSetterUpdatesAndClearsConfiguredRemoteEndpoint() {
    let context = makeStoreContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    context.store.setLegacyRemoteHost("192.168.1.99")

    let configured = context.store.endpoints()
    let configuredRemote = configured.first(where: \.isRemote)

    #expect(context.store.legacyRemoteHost() == "192.168.1.99")
    #expect(configuredRemote != nil)
    #expect(configuredRemote?.isDefault == true)
    #expect(configured.filter { $0.isRemote }.count == 1)

    context.store.setLegacyRemoteHost(nil)

    let cleared = context.store.endpoints()

    #expect(context.store.legacyRemoteHost() == nil)
    #expect(cleared.count == 1)
    #expect(cleared[0].isLocalManaged)
    #expect(cleared[0].isDefault)
  }

  @Test func crudSupportsUpsertDefaultEnableDisableAndRemove() {
    let context = makeStoreContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let remoteA = ServerEndpoint(
      name: "Remote A",
      wsURL: URL(string: "ws://10.0.0.1:4000/ws")!,
      isLocalManaged: false
    )
    var remoteB = ServerEndpoint(
      name: "Remote B",
      wsURL: URL(string: "ws://10.0.0.2:4000/ws")!,
      isLocalManaged: false
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

  private func makeStoreContext() -> (
    store: ServerEndpointStore,
    defaults: UserDefaults,
    suiteName: String,
    endpointsKey: String,
    legacyRemoteHostKey: String
  ) {
    let suiteName = "ServerEndpointStoreTests.\(UUID().uuidString)"
    let endpointsKey = "endpoints.\(UUID().uuidString)"
    let legacyKey = "legacy.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let store = ServerEndpointStore(
      defaults: defaults,
      endpointsKey: endpointsKey,
      legacyRemoteHostKey: legacyKey,
      defaultPort: 4_000
    )

    return (store, defaults, suiteName, endpointsKey, legacyKey)
  }
}
