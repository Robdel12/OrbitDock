import Foundation

struct HTTPRequestBuilder: Sendable {
  let baseURL: URL
  let authToken: String?

  func build(
    path: String,
    method: String,
    query: [URLQueryItem] = [],
    contentType: String? = nil,
    body: Data? = nil,
    timeoutInterval: TimeInterval = 15
  ) throws -> URLRequest {
    guard let url = buildURL(path: path, query: query) else {
      throw ServerRequestError.invalidEndpoint
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = timeoutInterval
    if let contentType {
      request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    }
    if let authToken, !authToken.isEmpty {
      request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = body
    return request
  }

  func buildURL(path: String, query: [URLQueryItem]) -> URL? {
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

  func encodePathComponent(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
  }
}
