//
//  ServerTypeAdapters.swift
//  OrbitDock
//
//  Detail-side protocol adaptation only.
//  Root-shell surfaces should stay on root-safe list records and never route
//  through these rich detail adapters.
//

import Foundation

// MARK: - ServerWorkStatus → Session types

extension ServerCodexIntegrationMode {
  func toSessionMode() -> CodexIntegrationMode {
    switch self {
      case .direct: .direct
      case .passive: .passive
    }
  }
}

extension ServerClaudeIntegrationMode {
  func toSessionMode() -> ClaudeIntegrationMode {
    switch self {
      case .direct: .direct
      case .passive: .passive
    }
  }
}

// MARK: - ServerWorkStatus → Session.WorkStatus

extension ServerWorkStatus {
  nonisolated func toSessionWorkStatus() -> Session.WorkStatus {
    switch self {
      case .working: .working
      case .waiting: .waiting
      case .permission: .permission
      case .question: .question
      case .reply: .reply
      case .ended: .ended
    }
  }

  nonisolated func toAttentionReason(hasPendingApproval: Bool = false) -> Session.AttentionReason {
    switch self {
      case .working: .none
      case .waiting: .awaitingReply
      case .reply: .awaitingReply
      case .permission: .awaitingPermission
      case .question: .awaitingQuestion
      case .ended: .none
    }
  }
}

// MARK: - ServerApprovalRequest helpers

extension ServerApprovalRequest {
  var toolNameForDisplay: String? {
    if let name = toolName, !name.isEmpty { return name }
    return switch type {
      case .exec: "Bash"
      case .patch: "Edit"
      case .question: nil
      case .permissions: "Permissions"
    }
  }

  var toolInputForDisplay: String? {
    guard let input = toolInput, !input.isEmpty else { return nil }
    return input
  }
}

// MARK: - Image Conversion (Lazy — no Data loaded at decode time)

extension ServerImageInput {
  func toMessageImage(index: Int, endpointId: UUID? = nil, sessionId: String) -> MessageImage? {
    let imageId = "\(inputType):\(value):\(index)"
    return switch inputType {
      case "url":
        messageImageFromDataURI(self, imageId: imageId)
      case "path":
        messageImageFromPath(self, imageId: imageId)
      case "attachment":
        messageImageFromAttachment(
          self,
          imageId: imageId,
          endpointId: endpointId,
          sessionId: sessionId
        )
      default:
        nil
    }
  }
}

private func messageImageFromPath(_ input: ServerImageInput, imageId: String) -> MessageImage? {
  let path = input.value
  let url = URL(fileURLWithPath: path)
  let byteCount = input.byteCount
    ?? ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
  let mimeType = input.mimeType ?? mimeTypeForExtension(url.pathExtension)
  return MessageImage(
    id: imageId,
    source: .filePath(path),
    mimeType: mimeType,
    byteCount: byteCount,
    pixelWidth: input.pixelWidth,
    pixelHeight: input.pixelHeight
  )
}

private func messageImageFromDataURI(_ input: ServerImageInput, imageId: String) -> MessageImage? {
  let uri = input.value
  guard uri.hasPrefix("data:") else { return nil }
  let withoutScheme = String(uri.dropFirst(5))
  guard let commaIndex = withoutScheme.firstIndex(of: ",") else { return nil }
  let meta = String(withoutScheme[withoutScheme.startIndex ..< commaIndex])
  guard meta.hasSuffix(";base64") else { return nil }
  let mimeType = String(meta.dropLast(7))
  // Estimate decoded size from base64 length (3 bytes per 4 chars)
  let base64Len = withoutScheme.distance(from: withoutScheme.index(after: commaIndex), to: withoutScheme.endIndex)
  let byteCount = input.byteCount ?? (base64Len * 3 / 4)
  return MessageImage(
    id: imageId,
    source: .dataURI(uri),
    mimeType: input.mimeType ?? (mimeType.isEmpty ? "image/png" : mimeType),
    byteCount: byteCount,
    pixelWidth: input.pixelWidth,
    pixelHeight: input.pixelHeight
  )
}

private func messageImageFromAttachment(
  _ input: ServerImageInput,
  imageId: String,
  endpointId: UUID?,
  sessionId: String
) -> MessageImage? {
  let mimeType = input.mimeType ?? mimeTypeForExtension(URL(fileURLWithPath: input.value).pathExtension)
  return MessageImage(
    id: imageId,
    source: .serverAttachment(
      ServerAttachmentImageReference(
        endpointId: endpointId,
        sessionId: sessionId,
        attachmentId: input.value
      )
    ),
    mimeType: mimeType,
    byteCount: input.byteCount ?? 0,
    pixelWidth: input.pixelWidth,
    pixelHeight: input.pixelHeight
  )
}

private func mimeTypeForExtension(_ ext: String) -> String {
  switch ext.lowercased() {
    case "png": "image/png"
    case "jpg", "jpeg": "image/jpeg"
    case "gif": "image/gif"
    case "webp": "image/webp"
    case "svg": "image/svg+xml"
    case "bmp": "image/bmp"
    case "tiff", "tif": "image/tiff"
    default: "image/png"
  }
}

// MARK: - Timestamp Parsing

/// Parse server timestamps (Unix seconds or ISO 8601)
func parseServerTimestamp(_ string: String?) -> Date? {
  guard let string, !string.isEmpty else { return nil }

  // Try Unix seconds first (what the Rust server sends: "1738800000Z")
  let stripped = string.hasSuffix("Z") ? String(string.dropLast()) : string
  if let seconds = TimeInterval(stripped) {
    return Date(timeIntervalSince1970: seconds)
  }

  // Try ISO 8601
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = formatter.date(from: string) {
    return date
  }

  // Try without fractional seconds
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.date(from: string)
}
