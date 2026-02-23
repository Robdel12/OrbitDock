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

  @Test func replaceRemoteEndpointSetsRemoteAsDefault() {
    let context = makeStoreContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    context.store.replaceRemoteEndpoint(hostInput: "10.0.0.5:4100")

    let endpoints = context.store.endpoints()
    let remote = endpoints.first(where: \.isRemote)

    #expect(endpoints.count == 2)
    #expect(remote != nil)
    #expect(remote?.isDefault == true)
    #expect(remote?.wsURL == URL(string: "ws://10.0.0.5:4100/ws"))
    #expect(context.store.hasRemoteEndpoint())
  }

  @Test func clearRemoteEndpointsLeavesLocalDefault() {
    let context = makeStoreContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    context.store.replaceRemoteEndpoint(hostInput: "192.168.1.99")
    context.store.clearRemoteEndpoints()

    let cleared = context.store.endpoints()

    #expect(context.store.remoteEndpoint() == nil)
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

  @Test func hostInputOmitsDefaultPort() {
    let defaultPortURL = URL(string: "ws://10.0.0.8:4000/ws")!
    let customPortURL = URL(string: "ws://10.0.0.8:4111/ws")!

    #expect(ServerEndpointStore.hostInput(from: defaultPortURL, defaultPort: 4_000) == "10.0.0.8")
    #expect(ServerEndpointStore.hostInput(from: customPortURL, defaultPort: 4_000) == "10.0.0.8:4111")
  }

  private func makeStoreContext() -> (
    store: ServerEndpointStore,
    defaults: UserDefaults,
    suiteName: String,
    endpointsKey: String
  ) {
    let suiteName = "ServerEndpointStoreTests.\(UUID().uuidString)"
    let endpointsKey = "endpoints.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let store = ServerEndpointStore(
      defaults: defaults,
      endpointsKey: endpointsKey,
      defaultPort: 4_000
    )

    return (store, defaults, suiteName, endpointsKey)
  }
}
