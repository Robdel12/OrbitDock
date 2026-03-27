import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ServerSettingsSheetPlannerTests {
  @Test func orderedEndpointsPrefersDefaultEnabledThenAlphabetical() throws {
    let endpoints = try [
      ServerEndpoint(
        id: #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
        name: "Zulu",
        wsURL: #require(URL(string: "ws://zulu/ws")),
        isEnabled: true,
        isDefault: false
      ),
      ServerEndpoint(
        id: #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")),
        name: "Alpha",
        wsURL: #require(URL(string: "ws://alpha/ws")),
        isEnabled: true,
        isDefault: true
      ),
      ServerEndpoint(
        id: #require(UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")),
        name: "Beta",
        wsURL: #require(URL(string: "ws://beta/ws")),
        isEnabled: false,
        isDefault: false
      ),
    ]

    let ordered = ServerSettingsSheetPlanner.orderedEndpoints(endpoints)

    #expect(ordered.map(\.name) == ["Alpha", "Zulu", "Beta"])
  }

  @Test func addDraftDefaultsToPrimaryOnlyWhenNoPrimaryExists() throws {
    let withoutPrimary = ServerSettingsSheetPlanner.addDraft(existingEndpoints: [])
    let withPrimary = try ServerSettingsSheetPlanner.addDraft(
      existingEndpoints: [
        ServerEndpoint(
          name: "Existing",
          wsURL: #require(URL(string: "ws://existing/ws")),
          isEnabled: true,
          isDefault: true
        ),
      ]
    )

    #expect(withoutPrimary.isDefault)
    #expect(!withPrimary.isDefault)
  }

  @Test func editDraftUsesEndpointFieldsAndProvidedHostInput() throws {
    let endpoint = try ServerEndpoint(
      id: #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
      name: "Remote",
      wsURL: #require(URL(string: "wss://remote.example/ws")),
      isEnabled: false,
      isDefault: true,
      authToken: "secret"
    )

    let draft = ServerSettingsSheetPlanner.editDraft(
      endpoint: endpoint,
      hostInput: "remote.example"
    )

    #expect(draft.name == "Remote")
    #expect(draft.hostInput == "remote.example")
    #expect(!draft.isEnabled)
    #expect(draft.isDefault)
    #expect(draft.authToken == "secret")
  }

  @Test func saveRejectsBlankNamesAndInvalidHosts() {
    let blankName = ServerSettingsSheetPlanner.save(
      currentEndpoints: [],
      editingEndpointID: nil,
      draft: ServerEndpointEditorDraft(
        name: "   ",
        hostInput: "server.example",
        isEnabled: true,
        isDefault: false,
        authToken: ""
      ),
      defaultPort: 4_000,
      buildURL: { _ in URL(string: "wss://server.example/ws") }
    )

    let invalidHost = ServerSettingsSheetPlanner.save(
      currentEndpoints: [],
      editingEndpointID: nil,
      draft: ServerEndpointEditorDraft(
        name: "Remote",
        hostInput: "bad host",
        isEnabled: true,
        isDefault: false,
        authToken: ""
      ),
      defaultPort: 4_000,
      buildURL: { _ in nil }
    )

    #expect(blankName == .failure(.missingName))
    #expect(invalidHost == .failure(.invalidHost))
  }

  @Test func saveAddsNewDefaultEndpointAndTrimsToken() throws {
    let existing = try ServerEndpoint(
      id: #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
      name: "Existing",
      wsURL: #require(URL(string: "ws://existing/ws")),
      isEnabled: true,
      isDefault: true
    )

    let result = ServerSettingsSheetPlanner.save(
      currentEndpoints: [existing],
      editingEndpointID: nil,
      draft: ServerEndpointEditorDraft(
        name: " Remote ",
        hostInput: "remote.example",
        isEnabled: true,
        isDefault: true,
        authToken: " token "
      ),
      defaultPort: 4_000,
      buildURL: { _ in URL(string: "wss://remote.example/ws") }
    )

    let updated = try result.get()
    let saved = try #require(updated.first(where: { $0.name == "Remote" }))

    #expect(saved.isDefault)
    #expect(saved.authToken == "token")
    #expect(updated.filter(\.isDefault).map(\.name) == ["Remote"])
  }

  @Test func saveRequiresAResolvableHostForEveryEndpoint() throws {
    let result = ServerSettingsSheetPlanner.save(
      currentEndpoints: [],
      editingEndpointID: nil,
      draft: ServerEndpointEditorDraft(
        name: "Loopback",
        hostInput: "127.0.0.1",
        isEnabled: true,
        isDefault: true,
        authToken: ""
      ),
      defaultPort: 4_000,
      buildURL: { input in
        URL(string: "ws://\(input):4000/ws")
      }
    )

    let updated = try result.get()
    #expect(updated.count == 1)
    #expect(updated.first?.name == "Loopback")
  }

  @Test func defaultAndEnabledMutationsPreserveSinglePrimarySemantics() throws {
    let endpointA = try ServerEndpoint(
      id: #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
      name: "A",
      wsURL: #require(URL(string: "ws://a/ws")),
      isEnabled: true,
      isDefault: true
    )
    let endpointB = try ServerEndpoint(
      id: #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")),
      name: "B",
      wsURL: #require(URL(string: "ws://b/ws")),
      isEnabled: false,
      isDefault: false
    )

    let defaulted = ServerSettingsSheetPlanner.defaultedEndpoints(
      currentEndpoints: [endpointA, endpointB],
      endpointID: endpointB.id
    )
    let disabled = ServerSettingsSheetPlanner.enabledEndpoints(
      currentEndpoints: defaulted,
      endpointID: endpointB.id,
      isEnabled: false
    )

    #expect(defaulted.first(where: { $0.id == endpointB.id })?.isEnabled == true)
    #expect(defaulted.filter(\.isDefault).map(\.id) == [endpointB.id])
    #expect(disabled.first(where: { $0.id == endpointB.id })?.isDefault == false)
  }

  @Test func removeDeletesAnyEndpoint() throws {
    let first = try ServerEndpoint(
      name: "First",
      wsURL: #require(URL(string: "ws://first/ws")),
      isEnabled: true,
      isDefault: true
    )
    let second = try ServerEndpoint(
      name: "Second",
      wsURL: #require(URL(string: "ws://second/ws")),
      isEnabled: true,
      isDefault: false
    )

    let afterFirstRemoval = ServerSettingsSheetPlanner.removedEndpoints(
      currentEndpoints: [first, second],
      removing: first
    )
    let afterSecondRemoval = ServerSettingsSheetPlanner.removedEndpoints(
      currentEndpoints: [first, second],
      removing: second
    )

    #expect(afterFirstRemoval.map(\.name) == ["Second"])
    #expect(afterSecondRemoval.map(\.name) == ["First"])
  }
}
