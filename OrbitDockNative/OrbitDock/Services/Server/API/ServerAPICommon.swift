import Foundation

struct ServerAcceptedResponse: Decodable {
  let accepted: Bool
}

struct ServerUploadedImageAttachmentResponse: Decodable {
  let image: ServerImageInput
}

struct ServerEmptyBody: Encodable {}

/// Full expanded content for a tool row, fetched on demand.
struct ServerRowContent: Decodable {
  let rowId: String
  let inputDisplay: String?
  let outputDisplay: String?
  let diffDisplay: String?
  let language: String?

  enum CodingKeys: String, CodingKey {
    case rowId = "row_id"
    case inputDisplay = "input_display"
    case outputDisplay = "output_display"
    case diffDisplay = "diff_display"
    case language
  }
}

enum ServerURLResolver {
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
