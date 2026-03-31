import Foundation

struct HTTPResponse: Sendable {
  let statusCode: Int
  let headers: [String: String]
  let body: Data

  nonisolated init(statusCode: Int, headers: [String: String], body: Data) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
  }

  nonisolated init(data: Data, response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else {
      throw HTTPTransportError.invalidResponse
    }
    self.statusCode = http.statusCode
    self.headers = http.allHeaderFields.reduce(into: [:]) { result, entry in
      guard let key = entry.key as? String else { return }
      result[key] = String(describing: entry.value)
    }
    self.body = data
  }

  nonisolated func headerValue(for field: String) -> String? {
    for (key, value) in headers {
      guard key.caseInsensitiveCompare(field) == .orderedSame else {
        continue
      }
      return value
    }
    return nil
  }
}

enum HTTPTransportError: LocalizedError, Equatable, Sendable {
  case cancelled
  case timedOut
  case unreachable(String)
  case serverUnreachable
  case transport(String)
  case invalidResponse

  init(error: any Error) {
    if let urlError = error as? URLError {
      switch urlError.code {
        case .cancelled:
          self = .cancelled
        case .timedOut:
          self = .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
          self = .unreachable(urlError.localizedDescription)
        default:
          self = .transport(urlError.localizedDescription)
      }
    } else {
      self = .transport(error.localizedDescription)
    }
  }

  var errorDescription: String? {
    switch self {
      case .cancelled:
        "Request cancelled."
      case .timedOut:
        "Request timed out."
      case let .unreachable(message):
        message
      case let .transport(message):
        message
      case .serverUnreachable:
        "Server is not reachable."
      case .invalidResponse:
        "Server returned an invalid response."
    }
  }
}
