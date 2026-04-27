import Foundation

final class ServerClients: Sendable {
  typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
  typealias ResponseLoader = @Sendable (URLRequest) async throws -> HTTPResponse

  let baseURL: URL
  let requestBuilder: HTTPRequestBuilder
  let http: ServerHTTPClient
  let sessionsSummary: SessionsSummaryClient
  let serverRole: ServerRoleClient
  let updates: ServerUpdateClient
  let config: ConfigClient
  let filesystem: FilesystemClient
  let skills: SkillsClient
  let capabilities: CapabilitiesClient
  let runtime: SessionRuntimeClient
  let controls: SessionControlsClient
  let usage: UsageClient
  let activeSessions: ActiveSessionsClient
  let archivedSessions: ArchivedSessionsClient
  let sessions: SessionsClient
  let conversation: ConversationClient
  let review: ReviewClient
  let approvals: ApprovalsClient
  let worktrees: WorktreesClient
  let missions: MissionsClient
  let imageLoader: ImageLoader

  convenience init(
    serverURL: URL,
    authToken: String?,
    dataLoader: @escaping DataLoader
  ) {
    let baseURL = ServerURLResolver.httpBaseURL(from: serverURL)
    let requestBuilder = HTTPRequestBuilder(baseURL: baseURL, authToken: authToken)
    self.init(
      baseURL: baseURL,
      requestBuilder: requestBuilder,
      responseLoader: { request in
        let raw = try await dataLoader(request)
        return try HTTPResponse(data: raw.0, response: raw.1)
      }
    )
  }

  init(
    baseURL: URL,
    requestBuilder: HTTPRequestBuilder,
    responseLoader: @escaping ResponseLoader
  ) {
    self.baseURL = baseURL
    self.requestBuilder = requestBuilder
    self.http = ServerHTTPClient(requestBuilder: requestBuilder, responseLoader: responseLoader)
    self.sessionsSummary = SessionsSummaryClient(http: http)
    self.serverRole = ServerRoleClient(http: http)
    self.updates = ServerUpdateClient(
      http: http,
      baseURL: baseURL,
      authToken: requestBuilder.authToken
    )
    self.config = ConfigClient(http: http)
    self.filesystem = FilesystemClient(http: http)
    self.skills = SkillsClient(http: http, requestBuilder: requestBuilder)
    self.capabilities = CapabilitiesClient(http: http, requestBuilder: requestBuilder)
    self.runtime = SessionRuntimeClient(http: http, requestBuilder: requestBuilder)
    self.controls = SessionControlsClient(http: http, requestBuilder: requestBuilder)
    self.usage = UsageClient(http: http, requestBuilder: requestBuilder)
    self.activeSessions = ActiveSessionsClient(http: http)
    self.archivedSessions = ArchivedSessionsClient(http: http)
    self.sessions = SessionsClient(http: http, requestBuilder: requestBuilder)
    self.conversation = ConversationClient(http: http, requestBuilder: requestBuilder)
    self.review = ReviewClient(http: http, requestBuilder: requestBuilder)
    self.approvals = ApprovalsClient(http: http, requestBuilder: requestBuilder)
    self.worktrees = WorktreesClient(http: http, requestBuilder: requestBuilder)
    self.missions = MissionsClient(http: http, requestBuilder: requestBuilder)
    self.imageLoader = ImageLoader(conversationClient: self.conversation)
    netLog(.info, cat: .api, "Initialized", data: ["baseURL": self.baseURL.absoluteString])
  }
}
