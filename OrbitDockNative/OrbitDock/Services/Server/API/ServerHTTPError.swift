import Foundation

enum ServerRequestError: LocalizedError {
  case notConnected
  case connectionLost
  case invalidEndpoint
  case invalidResponse
  case transport(HTTPTransportError)
  case httpStatus(Int, code: String? = nil, message: String? = nil)

  var statusCode: Int? {
    switch self {
      case let .httpStatus(status, _, _):
        status
      default:
        nil
    }
  }

  var apiErrorCode: String? {
    switch self {
      case let .httpStatus(_, code, _):
        code
      default:
        nil
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
      case let .transport(error):
        error.errorDescription
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

struct APIErrorResponse: Decodable {
  let code: String
  let error: String
}
