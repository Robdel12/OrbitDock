import Foundation

struct ConfigClient: Sendable {
  private let http: ServerHTTPClient

  init(http: ServerHTTPClient) {
    self.http = http
  }

  func setOpenAiKey(_ key: String) async throws {
    struct Body: Encodable { let key: String }
    struct Response: Decodable { let configured: Bool }
    let _: Response = try await http.post("/api/server/openai-key", body: Body(key: key))
  }

  func checkOpenAiKeyStatus() async throws -> Bool {
    struct Response: Decodable { let configured: Bool }
    let response: Response = try await http.get("/api/server/openai-key")
    return response.configured
  }
}
