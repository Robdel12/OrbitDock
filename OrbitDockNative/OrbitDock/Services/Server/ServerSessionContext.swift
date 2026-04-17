import Foundation

@MainActor
final class ServerSessionContext {
  let sessionId: String
  let endpointRuntime: ServerEndpointRuntime
  lazy var transport = ServerSessionTransport(sessionId: sessionId, endpointRuntime: endpointRuntime)
  lazy var api = ServerSessionAPI(sessionId: sessionId, endpointRuntime: endpointRuntime, transport: transport)

  init(sessionId: String, endpointRuntime: ServerEndpointRuntime) {
    self.sessionId = sessionId
    self.endpointRuntime = endpointRuntime
  }

  static func preview(sessionId: String = "preview-session") -> ServerSessionContext {
    ServerEndpointRuntime.preview().session(sessionId)
  }

  var endpointId: UUID {
    endpointRuntime.endpointId
  }

  var endpointName: String? {
    endpointRuntime.endpointName
  }

  var projectFileIndex: ProjectFileIndex {
    endpointRuntime.projectFileIndex
  }

  var clients: ServerClients {
    endpointRuntime.clients
  }

  var codexModels: [ServerCodexModelOption] {
    get { endpointRuntime.codexModels }
    set { endpointRuntime.codexModels = newValue }
  }

  var codexAccountStatus: ServerCodexAccountStatus? {
    endpointRuntime.codexAccountStatus
  }

  var codexAuthError: String? {
    endpointRuntime.codexAuthError
  }

  var codexAccountService: CodexAccountService {
    endpointRuntime.codexAccountService
  }

  var worktreesByRepo: [String: [ServerWorktreeSummary]] {
    endpointRuntime.worktreesByRepo
  }

  var serverInstanceId: String? {
    endpointRuntime.serverInstanceId
  }

  var lastServerError: (code: String, message: String)? {
    get { endpointRuntime.lastServerError }
    set { endpointRuntime.lastServerError = newValue }
  }

  var isRemoteConnection: Bool {
    endpointRuntime.connection.isRemote
  }

  func clearServerError() {
    endpointRuntime.clearServerError()
  }
}
