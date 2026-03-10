import Foundation

enum ConnectionStatus: Equatable, Hashable {
  case disconnected
  case connecting
  case connected
  case failed(String)
}

/// Thin composition root for the OrbitDock REST API.
///
/// The shape here is intentionally small:
/// - request building lives in `HTTPRequestBuilder`
/// - request execution lives in `HTTPTransport`
/// - generic decode/validation lives in `ServerHTTPClient`
/// - feature methods live in the `APIClient+*.swift` files for now
final class APIClient: Sendable {
  typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
  typealias ResponseLoader = @Sendable (URLRequest) async throws -> HTTPResponse

  let baseURL: URL
  let requestBuilder: HTTPRequestBuilder
  let http: ServerHTTPClient

  convenience init(serverURL: URL, authToken: String?) {
    let baseURL = Self.httpBaseURL(from: serverURL)
    let requestBuilder = HTTPRequestBuilder(baseURL: baseURL, authToken: authToken)
    let transport = HTTPTransport()
    self.init(
      baseURL: baseURL,
      requestBuilder: requestBuilder,
      responseLoader: { request in
        try await transport.execute(request)
      }
    )
  }

  convenience init(
    serverURL: URL,
    authToken: String?,
    dataLoader: @escaping DataLoader
  ) {
    let baseURL = Self.httpBaseURL(from: serverURL)
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
    netLog(.info, cat: .api, "Initialized", data: ["baseURL": self.baseURL.absoluteString])
  }
}

extension APIClient {
  func get<R: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> R {
    try await http.get(path, query: query)
  }

  func post<B: Encodable, R: Decodable>(
    _ path: String,
    body: B,
    query: [URLQueryItem] = []
  ) async throws -> R {
    try await http.post(path, body: body, query: query)
  }

  func request<R: Decodable>(
    path: String,
    method: String,
    query: [URLQueryItem] = []
  ) async throws -> R {
    try await http.request(path: path, method: method, query: query)
  }

  func request<B: Encodable, R: Decodable>(
    path: String,
    method: String,
    body: B,
    query: [URLQueryItem] = []
  ) async throws -> R {
    try await http.request(path: path, method: method, body: body, query: query)
  }

  func requestRaw<R: Decodable>(
    path: String,
    method: String,
    bodyData: Data,
    contentType: String,
    query: [URLQueryItem] = []
  ) async throws -> R {
    try await http.requestRaw(
      path: path,
      method: method,
      bodyData: bodyData,
      contentType: contentType,
      query: query
    )
  }

  func fireAndForget<B: Encodable>(
    _ path: String,
    method: String,
    body: B,
    query: [URLQueryItem] = []
  ) async throws {
    try await http.sendVoid(path, method: method, body: body, query: query)
  }

  func fireAndForgetRaw(
    _ path: String,
    method: String,
    bodyData: Data,
    query: [URLQueryItem] = []
  ) async throws {
    try await http.sendVoidRaw(path, method: method, bodyData: bodyData, query: query)
  }

  func fetchData(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
    try await http.fetchData(path, query: query)
  }

  func encode(_ value: String) -> String {
    requestBuilder.encodePathComponent(value)
  }

  static func httpBaseURL(from serverURL: URL) -> URL {
    guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
      return serverURL
    }
    if components.scheme == "wss" {
      components.scheme = "https"
    } else if components.scheme == "ws" {
      components.scheme = "http"
    }
    if components.path.hasSuffix("/ws") {
      components.path = String(components.path.dropLast(3))
    }
    return components.url ?? serverURL
  }
}

extension APIClient {
  struct SessionsListResponse: Decodable {
    let sessions: [ServerSessionSummary]
  }

  struct SessionSnapshotResponse: Decodable {
    let session: ServerSessionState
  }

  struct AcceptedResponse: Decodable {
    let accepted: Bool
  }

  struct UploadedImageAttachmentResponse: Decodable {
    let image: ServerImageInput
  }

  struct EmptyBody: Encodable {}
}
