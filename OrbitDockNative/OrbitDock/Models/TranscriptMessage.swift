//
//  TranscriptMessage.swift
//  OrbitDock
//

import Foundation

// MARK: - Message Image

nonisolated struct ServerAttachmentImageReference: Hashable {
  let endpointId: UUID?
  let sessionId: String
  let attachmentId: String
}

/// Lightweight image reference — stores only path/URI + metadata, never raw bytes.
/// Actual Data/NSImage loading is deferred to `ImageCache`.
nonisolated struct MessageImage: Identifiable, Hashable {
  /// How the image is referenced
  enum Source: Hashable {
    case filePath(String)
    case dataURI(String)
    case inlineData(Data)
    case serverAttachment(ServerAttachmentImageReference)
  }

  let id: String
  let source: Source
  let mimeType: String
  /// Pre-computed byte count for display (avoids loading data just to show size)
  let byteCount: Int
  let pixelWidth: Int?
  let pixelHeight: Int?

  init(
    id: String = UUID().uuidString,
    source: Source,
    mimeType: String,
    byteCount: Int,
    pixelWidth: Int? = nil,
    pixelHeight: Int? = nil
  ) {
    self.id = id
    self.source = source
    self.mimeType = mimeType
    self.byteCount = byteCount
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
  }
}

// MARK: - Transcript Message

nonisolated struct TranscriptMessage: Identifiable, Hashable {
  let id: String
  let sequence: UInt64?
  let type: MessageType
  let content: String
  let timestamp: Date
  let toolName: String?
  var toolDuration: TimeInterval? { didSet { recomputeContentSignature() } }
  let inputTokens: Int?
  let outputTokens: Int?
  var isError: Bool = false
  var isInProgress: Bool = false { didSet { recomputeContentSignature() } }
  var images: [MessageImage] = [] { didSet { recomputeContentSignature() } }
  var thinking: String? { didSet { recomputeContentSignature() } }

  /// Server-provided tool family string, if available.
  let serverToolFamily: String?

  /// Server-computed display metadata for tool messages.
  var toolDisplay: ServerToolDisplay?

  /// Resolved tool family — reads server value, falls back to local classification.
  var toolFamily: ToolFamily {
    if let serverToolFamily {
      let resolved = ToolFamily(serverValue: serverToolFamily)
      if resolved != .generic { return resolved }
    }
    return ToolFamily.classify(toolName: toolName, isShell: isShell)
  }

  var imageMimeType: String? {
    images.first?.mimeType
  }

  enum MessageType: String {
    case user
    case assistant
    case tool // Tool call from assistant
    case toolResult // Result of tool call
    case thinking // Claude's internal reasoning
    case system
    case steer // User guidance injected mid-turn
    case shell // User-initiated shell command
  }

  var isUser: Bool {
    type == .user
  }

  var isAssistant: Bool {
    type == .assistant
  }

  var isTool: Bool {
    type == .tool
  }

  var isToolLike: Bool {
    type == .tool || type == .shell
  }

  var isThinking: Bool {
    type == .thinking
  }

  var isSteer: Bool {
    type == .steer
  }

  var isShell: Bool {
    type == .shell
  }

  /// Precomputed hash of all renderable content fields.
  /// The projector combines this single Int instead of re-scanning text on every pass.
  private(set) var contentSignature: Int = 0

  init(
    id: String,
    sequence: UInt64? = nil,
    type: MessageType,
    content: String,
    timestamp: Date,
    toolName: String? = nil,
    toolDuration: TimeInterval? = nil,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    isError: Bool = false,
    isInProgress: Bool = false,
    images: [MessageImage] = [],
    thinking: String? = nil,
    serverToolFamily: String? = nil,
    toolDisplay: ServerToolDisplay? = nil
  ) {
    self.id = id
    self.sequence = sequence
    self.type = type
    self.content = content
    self.timestamp = timestamp
    self.toolName = toolName
    self.toolDuration = toolDuration
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.isError = isError
    self.isInProgress = isInProgress
    self.images = images
    self.thinking = thinking
    self.serverToolFamily = serverToolFamily
    self.toolDisplay = toolDisplay
    self.contentSignature = Self.computeContentSignature(
      content: content, thinking: thinking,
      toolName: toolName, toolDuration: toolDuration,
      inputTokens: inputTokens, outputTokens: outputTokens,
      isInProgress: isInProgress, images: images
    )
  }

  private mutating func recomputeContentSignature() {
    contentSignature = Self.computeContentSignature(
      content: content, thinking: thinking,
      toolName: toolName, toolDuration: toolDuration,
      inputTokens: inputTokens, outputTokens: outputTokens,
      isInProgress: isInProgress, images: images
    )
  }

  private static func computeContentSignature(
    content: String, thinking: String?,
    toolName: String?, toolDuration: TimeInterval?,
    inputTokens: Int?, outputTokens: Int?,
    isInProgress: Bool, images: [MessageImage]
  ) -> Int {
    var h = Hasher()
    h.combine(content)
    h.combine(thinking)
    h.combine(toolName)
    h.combine(toolDuration)
    h.combine(inputTokens)
    h.combine(outputTokens)
    h.combine(isInProgress)
    h.combine(images.count)
    for img in images {
      h.combine(img.id)
      h.combine(img.source)
      h.combine(img.mimeType)
      h.combine(img.byteCount)
      h.combine(img.pixelWidth)
      h.combine(img.pixelHeight)
    }
    return h.finalize()
  }

  var isBashLikeCommand: Bool {
    isShell || toolName?.lowercased() == "bash"
  }

  /// Hashable conformance - exclude toolInput since [String: Any] isn't Hashable
  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(sequence)
    hasher.combine(type)
    hasher.combine(content)
    hasher.combine(timestamp)
    hasher.combine(toolName)
    hasher.combine(images)
  }

  var hasImage: Bool {
    !images.isEmpty
  }

  var hasThinking: Bool {
    thinking != nil && !thinking!.isEmpty
  }

  static func == (lhs: TranscriptMessage, rhs: TranscriptMessage) -> Bool {
    lhs.id == rhs.id
      && lhs.sequence == rhs.sequence
      && lhs.content == rhs.content
      && lhs.isError == rhs.isError
      && lhs.isInProgress == rhs.isInProgress
      && lhs.images == rhs.images
      && lhs.thinking == rhs.thinking
  }

  var preview: String {
    let cleaned = content
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.count > 200 {
      return String(cleaned.prefix(200)) + "..."
    }
    return cleaned
  }
}
