import Foundation

struct ServerHTTPClient: Sendable {
  let requestBuilder: HTTPRequestBuilder
  let responseLoader: @Sendable (URLRequest) async throws -> HTTPResponse

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return encoder
  }()

  private static let decoder = JSONDecoder()

  private func debugPreview(_ data: Data, maxCharacters: Int = 600) -> String {
    guard let text = String(data: data, encoding: .utf8) else {
      return "<non-utf8 body: \(data.count) bytes>"
    }
    if text.count <= maxCharacters {
      return text
    }
    return String(text.prefix(maxCharacters)) + "…"
  }

  private func describeDecodingError(_ error: Error) -> String {
    func pathString(_ path: [CodingKey]) -> String {
      guard !path.isEmpty else { return "<root>" }
      return path.map { key in
        if let index = key.intValue {
          return "[\(index)]"
        }
        return key.stringValue
      }
      .joined(separator: ".")
      .replacingOccurrences(of: ".[", with: "[")
    }

    switch error {
      case let DecodingError.keyNotFound(key, context):
        return "Missing key '\(key.stringValue)' at \(pathString(context.codingPath)): \(context.debugDescription)"
      case let DecodingError.typeMismatch(type, context):
        return "Type mismatch for \(type) at \(pathString(context.codingPath)): \(context.debugDescription)"
      case let DecodingError.valueNotFound(type, context):
        return "Missing value for \(type) at \(pathString(context.codingPath)): \(context.debugDescription)"
      case let DecodingError.dataCorrupted(context):
        return "Data corrupted at \(pathString(context.codingPath)): \(context.debugDescription)"
      default:
        return error.localizedDescription
    }
  }

  func get<R: Decodable>(
    _ path: String,
    query: [URLQueryItem] = []
  ) async throws -> R {
    try await request(path: path, method: "GET", query: query)
  }

  func post<R: Decodable>(
    _ path: String,
    body: some Encodable,
    query: [URLQueryItem] = []
  ) async throws -> R {
    try await request(path: path, method: "POST", body: body, query: query)
  }

  func request<R: Decodable>(
    path: String,
    method: String,
    query: [URLQueryItem] = []
  ) async throws -> R {
    netLog(.debug, cat: .api, "→ \(method) \(path)")
    let request = try requestBuilder.build(path: path, method: method, query: query)
    let response = try await loadResponse(request)
    try validate(response: response, method: method, path: path)
    do {
      return try Self.decoder.decode(R.self, from: response.body)
    } catch {
      let detailedError = describeDecodingError(error)
      netLog(.error, cat: .api, "Decode failed \(method) \(path)", data: ["error": detailedError])
      print("[OrbitDock][HTTP] Decode failed \(method) \(path)")
      print("[OrbitDock][HTTP] Error: \(detailedError)")
      print("[OrbitDock][HTTP] Body preview: \(debugPreview(response.body))")
      throw error
    }
  }

  func request<R: Decodable>(
    path: String,
    method: String,
    body: some Encodable,
    query: [URLQueryItem] = []
  ) async throws -> R {
    netLog(.debug, cat: .api, "→ \(method) \(path)")
    let request = try requestBuilder.build(
      path: path,
      method: method,
      query: query,
      contentType: "application/json",
      body: Self.encoder.encode(body)
    )
    let response = try await loadResponse(request)
    try validate(response: response, method: method, path: path)
    do {
      return try Self.decoder.decode(R.self, from: response.body)
    } catch {
      let detailedError = describeDecodingError(error)
      netLog(.error, cat: .api, "Decode failed \(method) \(path)", data: ["error": detailedError])
      print("[OrbitDock][HTTP] Decode failed \(method) \(path)")
      print("[OrbitDock][HTTP] Error: \(detailedError)")
      print("[OrbitDock][HTTP] Body preview: \(debugPreview(response.body))")
      throw error
    }
  }

  func requestRaw<R: Decodable>(
    path: String,
    method: String,
    bodyData: Data,
    contentType: String,
    query: [URLQueryItem] = []
  ) async throws -> R {
    netLog(.debug, cat: .api, "→ \(method) \(path)")
    let request = try requestBuilder.build(
      path: path,
      method: method,
      query: query,
      contentType: contentType,
      body: bodyData,
      timeoutInterval: 30
    )
    let response = try await loadResponse(request)
    try validate(response: response, method: method, path: path)
    do {
      return try Self.decoder.decode(R.self, from: response.body)
    } catch {
      let detailedError = describeDecodingError(error)
      netLog(.error, cat: .api, "Decode failed \(method) \(path)", data: ["error": detailedError])
      print("[OrbitDock][HTTP] Decode failed \(method) \(path)")
      print("[OrbitDock][HTTP] Error: \(detailedError)")
      print("[OrbitDock][HTTP] Body preview: \(debugPreview(response.body))")
      throw error
    }
  }

  func sendVoid(
    _ path: String,
    method: String,
    body: some Encodable,
    query: [URLQueryItem] = []
  ) async throws {
    netLog(.debug, cat: .api, "→ \(method) \(path)")
    let request = try requestBuilder.build(
      path: path,
      method: method,
      query: query,
      contentType: "application/json",
      body: Self.encoder.encode(body)
    )
    let response = try await loadResponse(request)
    try validate(response: response, method: method, path: path)
  }

  func sendVoidRaw(
    _ path: String,
    method: String,
    bodyData: Data,
    query: [URLQueryItem] = []
  ) async throws {
    netLog(.debug, cat: .api, "→ \(method) \(path)")
    let request = try requestBuilder.build(
      path: path,
      method: method,
      query: query,
      contentType: "application/json",
      body: bodyData
    )
    let response = try await loadResponse(request)
    try validate(response: response, method: method, path: path)
  }

  func fetchData(
    _ path: String,
    query: [URLQueryItem] = []
  ) async throws -> Data {
    netLog(.debug, cat: .api, "→ GET \(path)")
    let request = try requestBuilder.build(
      path: path,
      method: "GET",
      query: query,
      timeoutInterval: 30
    )
    let response = try await loadResponse(request)
    try validate(response: response, method: "GET", path: path)
    return response.body
  }

  func sendRaw(
    path: String,
    method: String,
    bodyData: Data,
    contentType: String = "application/json",
    query: [URLQueryItem] = []
  ) async throws -> HTTPResponse {
    netLog(.debug, cat: .api, "→ \(method) \(path)")
    let request = try requestBuilder.build(
      path: path,
      method: method,
      query: query,
      contentType: contentType,
      body: bodyData
    )
    let response = try await loadResponse(request)
    try validate(response: response, method: method, path: path)
    return response
  }

  private func loadResponse(_ request: URLRequest) async throws -> HTTPResponse {
    do {
      return try await responseLoader(request)
    } catch let error as HTTPTransportError {
      throw ServerRequestError.transport(error)
    } catch let error as ServerRequestError {
      throw error
    } catch {
      throw ServerRequestError.transport(HTTPTransportError(error: error))
    }
  }

  private func validate(response: HTTPResponse, method: String, path: String) throws {
    guard (200 ..< 300).contains(response.statusCode) else {
      let apiError = try? Self.decoder.decode(APIErrorResponse.self, from: response.body)
      netLog(
        .error,
        cat: .api,
        "HTTP \(response.statusCode) \(method) \(path)",
        data: ["code": apiError?.code ?? "-", "error": apiError?.error ?? "-"]
      )
      throw ServerRequestError.httpStatus(
        response.statusCode,
        code: apiError?.code,
        message: apiError?.error
      )
    }
  }
}
