//
//  APIClient.swift
//  OrbitDock
//
//  Standalone HTTP transport for the OrbitDock server.
//  No state, no callbacks — pure async/await.
//

import Foundation

private let liveAPIClientURLSession: URLSession = {
  let configuration = URLSessionConfiguration.default
  configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
  configuration.urlCache = nil
  return URLSession(configuration: configuration)
}()

private func liveAPIClientDataLoader(_ request: URLRequest) async throws -> (Data, URLResponse) {
  try await liveAPIClientURLSession.data(for: request)
}

// MARK: - Connection Status

enum ConnectionStatus: Equatable, Hashable {
  case disconnected
  case connecting
  case connected
  case failed(String)
}

// MARK: - Errors

enum ServerRequestError: LocalizedError {
  case notConnected
  case connectionLost
  case invalidEndpoint
  case invalidResponse
  case httpStatus(Int, code: String? = nil, message: String? = nil)

  var statusCode: Int? {
    switch self {
    case let .httpStatus(status, _, _): status
    default: nil
    }
  }

  var apiErrorCode: String? {
    switch self {
    case let .httpStatus(_, code, _): code
    default: nil
    }
  }

  var isConnectorUnavailableConflict: Bool {
    statusCode == 409 && apiErrorCode == "session_not_found"
  }

  var errorDescription: String? {
    switch self {
    case .notConnected:
      "Server is not connected."
    case .connectionLost:
      "Server connection was lost before the request completed."
    case .invalidEndpoint:
      "Server endpoint URL is invalid."
    case .invalidResponse:
      "Server returned an invalid response."
    case let .httpStatus(status, code, message):
      if let code, let message {
        "Server request failed with status \(status) (\(code)): \(message)"
      } else if let code {
        "Server request failed with status \(status) (\(code))."
      } else {
        "Server request failed with status \(status)."
      }
    }
  }
}

// MARK: - APIClient

/// Pure HTTP transport for the OrbitDock server REST API.
/// Stateless — callers supply the base URL and auth token on init.
final class APIClient: Sendable {
  typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

  let baseURL: URL
  private let authToken: String?
  private let dataLoader: DataLoader

  static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.keyEncodingStrategy = .convertToSnakeCase
    return e
  }()

  static let decoder = JSONDecoder()

  convenience init(serverURL: URL, authToken: String?) {
    self.init(serverURL: serverURL, authToken: authToken, dataLoader: liveAPIClientDataLoader)
  }

  init(
    serverURL: URL,
    authToken: String?,
    dataLoader: @escaping DataLoader
  ) {
    self.baseURL = Self.httpBaseURL(from: serverURL)
    self.authToken = authToken
    self.dataLoader = dataLoader
    netLog(.info, cat: .api, "Initialized", data: ["baseURL": self.baseURL.absoluteString])
  }
}

// MARK: - HTTP Primitives

extension APIClient {

  /// GET that decodes JSON response.
  func get<R: Decodable>(
    _ path: String, query: [URLQueryItem] = []
  ) async throws -> R {
    try await request(path: path, method: "GET", query: query)
  }

  /// POST with Encodable body that decodes JSON response.
  func post<B: Encodable, R: Decodable>(
    _ path: String, body: B, query: [URLQueryItem] = []
  ) async throws -> R {
    try await request(path: path, method: "POST", body: body, query: query)
  }

  /// Request with optional body, decoding JSON response.
  func request<R: Decodable>(
    path: String, method: String, query: [URLQueryItem] = []
  ) async throws -> R {
    netLog(.debug, cat: .api, "→ \(method) \(path)")
    guard let url = buildURL(path: path, query: query) else {
      throw ServerRequestError.invalidEndpoint
    }

    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = 15
    applyAuth(to: &req)

    let (data, response) = try await dataLoader(req)
    try validateHTTPResponse(response, data: data, method: method, path: path)
    do {
      return try Self.decoder.decode(R.self, from: data)
    } catch {
      netLog(.error, cat: .api, "Decode failed \(method) \(path)", data: ["error": error.localizedDescription])
      throw error
    }
  }

  /// Request with Encodable body, decoding JSON response.
  func request<B: Encodable, R: Decodable>(
    path: String, method: String, body: B, query: [URLQueryItem] = []
  ) async throws -> R {
    netLog(.debug, cat: .api, "→ \(method) \(path)")
    guard let url = buildURL(path: path, query: query) else {
      throw ServerRequestError.invalidEndpoint
    }

    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = 15
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applyAuth(to: &req)
    req.httpBody = try Self.encoder.encode(body)

    let (data, response) = try await dataLoader(req)
    try validateHTTPResponse(response, data: data, method: method, path: path)
    do {
      return try Self.decoder.decode(R.self, from: data)
    } catch {
      netLog(.error, cat: .api, "Decode failed \(method) \(path)", data: ["error": error.localizedDescription])
      throw error
    }
  }

  /// Fire-and-forget: sends body, validates 2xx, discards response body.
  func fireAndForget<B: Encodable>(
    _ path: String, method: String, body: B, query: [URLQueryItem] = []
  ) async throws {
    netLog(.debug, cat: .api, "→ \(method) \(path)")
    guard let url = buildURL(path: path, query: query) else {
      throw ServerRequestError.invalidEndpoint
    }

    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = 15
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applyAuth(to: &req)
    req.httpBody = try Self.encoder.encode(body)

    let (data, response) = try await dataLoader(req)
    try validateHTTPResponse(response, data: data, method: method, path: path)
  }

  /// Fire-and-forget with raw Data body.
  func fireAndForgetRaw(
    _ path: String, method: String, bodyData: Data, query: [URLQueryItem] = []
  ) async throws {
    netLog(.debug, cat: .api, "→ \(method) \(path)")
    guard let url = buildURL(path: path, query: query) else {
      throw ServerRequestError.invalidEndpoint
    }

    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = 15
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applyAuth(to: &req)
    req.httpBody = bodyData

    let (data, response) = try await dataLoader(req)
    try validateHTTPResponse(response, data: data, method: method, path: path)
  }

  /// Send raw Data body with custom content type, decode JSON response.
  func requestRaw<R: Decodable>(
    path: String, method: String, bodyData: Data, contentType: String,
    query: [URLQueryItem] = []
  ) async throws -> R {
    netLog(.debug, cat: .api, "→ \(method) \(path)")
    guard let url = buildURL(path: path, query: query) else {
      throw ServerRequestError.invalidEndpoint
    }

    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = 30
    req.setValue(contentType, forHTTPHeaderField: "Content-Type")
    applyAuth(to: &req)
    req.httpBody = bodyData

    let (data, response) = try await dataLoader(req)
    try validateHTTPResponse(response, data: data, method: method, path: path)
    do {
      return try Self.decoder.decode(R.self, from: data)
    } catch {
      netLog(.error, cat: .api, "Decode failed \(method) \(path)", data: ["error": error.localizedDescription])
      throw error
    }
  }

  /// Fetch raw Data (GET).
  func fetchData(
    _ path: String, query: [URLQueryItem] = []
  ) async throws -> Data {
    netLog(.debug, cat: .api, "→ GET \(path)")
    guard let url = buildURL(path: path, query: query) else {
      throw ServerRequestError.invalidEndpoint
    }

    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.timeoutInterval = 30
    applyAuth(to: &req)

    let (data, response) = try await dataLoader(req)
    try validateHTTPResponse(response, data: data, method: "GET", path: path)
    return data
  }

  private func applyAuth(to request: inout URLRequest) {
    if let authToken, !authToken.isEmpty {
      request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    }
  }

  private func validateHTTPResponse(
    _ response: URLResponse, data: Data, method: String = "?", path: String = "?"
  ) throws {
    guard let http = response as? HTTPURLResponse else {
      netLog(.error, cat: .api, "Invalid response \(method) \(path)")
      throw ServerRequestError.invalidResponse
    }
    guard (200 ..< 300).contains(http.statusCode) else {
      let apiError = try? Self.decoder.decode(APIErrorResponse.self, from: data)
      netLog(.error, cat: .api, "HTTP \(http.statusCode) \(method) \(path)", data: ["code": apiError?.code ?? "-", "error": apiError?.error ?? "-"])
      throw ServerRequestError.httpStatus(
        http.statusCode,
        code: apiError?.code,
        message: apiError?.error
      )
    }
  }

  private func buildURL(path: String, query: [URLQueryItem]) -> URL? {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      return nil
    }
    let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
    if components.path.isEmpty || components.path == "/" {
      components.path = normalizedPath
    } else {
      var base = components.path
      if base.hasSuffix("/") { base.removeLast() }
      components.path = "\(base)\(normalizedPath)"
    }
    components.queryItems = query.isEmpty ? nil : query
    return components.url
  }

  func encode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
  }

  /// Convert ws/wss server URL to http/https base URL (stripping /ws path suffix).
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

// MARK: - Shared Response Types

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

  struct APIErrorResponse: Decodable {
    let code: String
    let error: String
  }

  struct UploadedImageAttachmentResponse: Decodable {
    let image: ServerImageInput
  }

  struct EmptyBody: Encodable {}
}
