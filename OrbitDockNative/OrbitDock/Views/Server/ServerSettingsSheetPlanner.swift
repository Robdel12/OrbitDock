import Foundation

struct ServerEndpointEditorDraft: Equatable {
  var name: String
  var hostInput: String
  var isEnabled: Bool
  var isDefault: Bool
  var isLocalManaged: Bool
  var authToken: String
}

enum ServerSettingsEditorValidationError: Error, Equatable {
  case missingName
  case invalidHost

  var message: String {
    switch self {
      case .missingName:
        "Endpoint name is required."
      case .invalidHost:
        "Enter a valid host (e.g. 10.0.0.5:4000 or https://host.example)."
    }
  }
}

@MainActor
enum ServerSettingsSheetPlanner {
  static func orderedEndpoints(_ endpoints: [ServerEndpoint]) -> [ServerEndpoint] {
    endpoints.sorted { lhs, rhs in
      if lhs.isDefault != rhs.isDefault {
        return lhs.isDefault && !rhs.isDefault
      }
      if lhs.isEnabled != rhs.isEnabled {
        return lhs.isEnabled && !rhs.isEnabled
      }
      if lhs.isLocalManaged != rhs.isLocalManaged {
        return lhs.isLocalManaged && !rhs.isLocalManaged
      }
      let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
      if nameOrder != .orderedSame {
        return nameOrder == .orderedAscending
      }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  static func addDraft(
    existingEndpoints: [ServerEndpoint]
  ) -> ServerEndpointEditorDraft {
    ServerEndpointEditorDraft(
      name: "",
      hostInput: "",
      isEnabled: true,
      isDefault: existingEndpoints.first(where: \.isDefault) == nil,
      isLocalManaged: false,
      authToken: ""
    )
  }

  static func editDraft(
    endpoint: ServerEndpoint,
    hostInput: String
  ) -> ServerEndpointEditorDraft {
    ServerEndpointEditorDraft(
      name: endpoint.name,
      hostInput: hostInput,
      isEnabled: endpoint.isEnabled,
      isDefault: endpoint.isDefault,
      isLocalManaged: endpoint.isLocalManaged,
      authToken: endpoint.authToken ?? ""
    )
  }

  static func save(
    currentEndpoints: [ServerEndpoint],
    editingEndpointID: UUID?,
    draft: ServerEndpointEditorDraft,
    defaultPort: Int,
    buildURL: (String) -> URL?
  ) -> Result<[ServerEndpoint], ServerSettingsEditorValidationError> {
    let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      return .failure(.missingName)
    }

    let endpointID = editingEndpointID ?? UUID()
    let existingEndpoint = currentEndpoints.first(where: { $0.id == endpointID })
    let isLocalManaged = existingEndpoint?.isLocalManaged ?? draft.isLocalManaged

    let resolvedURL: URL
    if isLocalManaged {
      resolvedURL = existingEndpoint?.wsURL
        ?? ServerEndpoint.localDefault(defaultPort: defaultPort).wsURL
    } else {
      guard let built = buildURL(draft.hostInput) else {
        return .failure(.invalidHost)
      }
      resolvedURL = built
    }

    let trimmedToken = draft.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
    let endpoint = ServerEndpoint(
      id: endpointID,
      name: trimmedName,
      wsURL: resolvedURL,
      isLocalManaged: isLocalManaged,
      isEnabled: draft.isEnabled,
      isDefault: draft.isEnabled && draft.isDefault,
      authToken: trimmedToken.isEmpty ? nil : trimmedToken
    )

    var updated = currentEndpoints
    if let index = updated.firstIndex(where: { $0.id == endpointID }) {
      updated[index] = endpoint
    } else {
      updated.append(endpoint)
    }

    if endpoint.isDefault {
      for index in updated.indices {
        updated[index].isDefault = updated[index].id == endpoint.id
      }
    }

    return .success(updated)
  }

  static func removedEndpoints(
    currentEndpoints: [ServerEndpoint],
    removing endpoint: ServerEndpoint
  ) -> [ServerEndpoint] {
    currentEndpoints.filter { $0.id != endpoint.id }
  }

  static func defaultedEndpoints(
    currentEndpoints: [ServerEndpoint],
    endpointID: UUID
  ) -> [ServerEndpoint] {
    var updated = currentEndpoints
    guard let index = updated.firstIndex(where: { $0.id == endpointID }) else { return updated }

    updated[index].isEnabled = true
    for index in updated.indices {
      updated[index].isDefault = updated[index].id == endpointID
    }
    return updated
  }

  static func enabledEndpoints(
    currentEndpoints: [ServerEndpoint],
    endpointID: UUID,
    isEnabled: Bool
  ) -> [ServerEndpoint] {
    var updated = currentEndpoints
    guard let index = updated.firstIndex(where: { $0.id == endpointID }) else { return updated }

    updated[index].isEnabled = isEnabled
    if !isEnabled {
      updated[index].isDefault = false
    }
    return updated
  }
}
