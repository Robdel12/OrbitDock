import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ServerSettingsSheetPlannerTests {
  @Test func orderedEndpointsPrefersDefaultEnabledAndLocalManaged() throws {
    let endpoints = try [
      ServerEndpoint(
        id: #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
        name: "Zulu",
        wsURL: #require(URL(string: "ws://zulu/ws")),
        isLocalManaged: false,
        isEnabled: true,
        isDefault: false
      ),
      ServerEndpoint(
        id: #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")),
        name: "Alpha",
        wsURL: #require(URL(string: "ws://alpha/ws")),
        isLocalManaged: true,
        isEnabled: true,
        isDefault: true
      ),
      ServerEndpoint(
        id: #require(UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")),
        name: "Beta",
        wsURL: #require(URL(string: "ws://beta/ws")),
        isLocalManaged: false,
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
          isLocalManaged: false,
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
      isLocalManaged: false,
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
        isLocalManaged: false,
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
        isLocalManaged: false,
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
      isLocalManaged: false,
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
        isLocalManaged: false,
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

  @Test func savePreservesLocalManagedURLForExistingLocalEndpoint() throws {
    let local = ServerEndpoint.localDefault()

    let result = ServerSettingsSheetPlanner.save(
      currentEndpoints: [local],
      editingEndpointID: local.id,
      draft: ServerEndpointEditorDraft(
        name: "Local Server",
        hostInput: "ignored",
        isEnabled: true,
        isDefault: true,
        isLocalManaged: true,
        authToken: ""
      ),
      defaultPort: 4_000,
      buildURL: { _ in nil }
    )

    let updated = try result.get()
    #expect(updated.first?.wsURL == local.wsURL)
  }

  @Test func defaultAndEnabledMutationsPreserveSinglePrimarySemantics() throws {
    let endpointA = try ServerEndpoint(
      id: #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
      name: "A",
      wsURL: #require(URL(string: "ws://a/ws")),
      isLocalManaged: false,
      isEnabled: true,
      isDefault: true
    )
    let endpointB = try ServerEndpoint(
      id: #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")),
      name: "B",
      wsURL: #require(URL(string: "ws://b/ws")),
      isLocalManaged: false,
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

  @Test func removeLeavesLocalManagedEndpointsUntouched() throws {
    let local = ServerEndpoint.localDefault()
    let remote = try ServerEndpoint(
      name: "Remote",
      wsURL: #require(URL(string: "ws://remote/ws")),
      isLocalManaged: false,
      isEnabled: true,
      isDefault: false
    )

    let afterLocalRemoval = ServerSettingsSheetPlanner.removedEndpoints(
      currentEndpoints: [local, remote],
      removing: local
    )
    let afterRemoteRemoval = ServerSettingsSheetPlanner.removedEndpoints(
      currentEndpoints: [local, remote],
      removing: remote
    )

    #expect(afterLocalRemoval.map(\.name) == ["Local Server", "Remote"])
    #expect(afterRemoteRemoval.map(\.name) == ["Local Server"])
  }
}
