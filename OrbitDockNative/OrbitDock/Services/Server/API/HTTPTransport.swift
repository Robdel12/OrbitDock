import Foundation

final class HTTPTransport: @unchecked Sendable {
  private let urlSession: URLSession

  init(urlSession: URLSession = HTTPTransport.makeLiveSession()) {
    self.urlSession = urlSession
  }

  func execute(_ request: URLRequest) async throws -> HTTPResponse {
    let result: (Data, URLResponse) = try await withCheckedThrowingContinuation { continuation in
      let task = urlSession.dataTask(with: request) { data, response, error in
        if let error {
          continuation.resume(throwing: HTTPTransportError(error: error))
        } else if let data, let response {
          continuation.resume(returning: (data, response))
        } else {
          continuation.resume(throwing: HTTPTransportError.invalidResponse)
        }
      }

      task.resume()
    }

    return try HTTPResponse(data: result.0, response: result.1)
  }

  private static func makeLiveSession() -> URLSession {
    let configuration = URLSessionConfiguration.default
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
  }
}
