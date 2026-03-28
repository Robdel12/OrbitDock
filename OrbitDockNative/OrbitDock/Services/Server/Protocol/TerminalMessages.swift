import Foundation

// MARK: - Client → Server Terminal Messages

struct TerminalCreatePayload: Encodable {
  let type: String
  let terminalId: String
  let cwd: String
  let shell: String?
  let cols: UInt16
  let rows: UInt16
  let sessionId: String?
}

struct TerminalInputPayload: Encodable {
  let type: String
  let terminalId: String
  /// Base64-encoded bytes.
  let data: String
}

struct TerminalResizePayload: Encodable {
  let type: String
  let terminalId: String
  let cols: UInt16
  let rows: UInt16
}

struct TerminalDestroyPayload: Encodable {
  let type: String
  let terminalId: String
}
