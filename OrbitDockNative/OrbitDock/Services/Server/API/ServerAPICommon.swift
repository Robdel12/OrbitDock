import Foundation

struct ServerAcceptedResponse: Decodable {
  let accepted: Bool
}

struct ServerUploadedImageAttachmentResponse: Decodable {
  let image: ServerImageInput
}

struct ServerEmptyBody: Encodable {}

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
