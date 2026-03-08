//
//  ConversationRichMessageRowModel.swift
//  OrbitDock
//
//  Shared row model for native rich-message timeline cells.
//

import SwiftUI

struct NativeRichMessageRowModel {
  let messageID: String
  let speaker: String
  let content: String
  let thinking: String?
  let messageType: MessageType
  let timestamp: Date
  let hasImages: Bool
  let images: [MessageImage]
  /// Whether thinking content is expanded (only relevant for .thinking type)
  var isThinkingExpanded: Bool = false
  /// Whether to show the speaker header (glyph + optional label).
  /// False when the previous row is the same role — reduces visual noise.
  var showHeader: Bool = true

  /// Max characters to show in collapsed thinking preview (matches SwiftUI)
  static let maxThinkingPreviewLength = 600

  enum MessageType {
    case user
    case assistant
    case thinking
    case steer
    case shell
    case error
  }

  /// The display content for this row — truncated for collapsed thinking.
  var displayContent: String {
    if messageType == .thinking, !isThinkingExpanded,
       content.count > Self.maxThinkingPreviewLength
    {
      let prefix = content.prefix(Self.maxThinkingPreviewLength)
      // Truncate at a word boundary to avoid mid-word cutoff
      if let lastSpace = prefix.lastIndex(where: { $0.isWhitespace }) {
        return String(prefix[prefix.startIndex ..< lastSpace])
      }
      return String(prefix)
    }
    return content
  }

  /// Whether the thinking content is long enough to truncate.
  var isThinkingLong: Bool {
    messageType == .thinking && content.count > Self.maxThinkingPreviewLength
  }

  var speakerColor: PlatformColor {
    switch messageType {
      case .user:
        PlatformColor(Color.accent).withAlphaComponent(0.8)
      case .assistant:
        PlatformColor(Color.textSecondary)
      case .thinking:
        PlatformColor.calibrated(red: 0.65, green: 0.6, blue: 0.85, alpha: 0.9)
      case .steer:
        PlatformColor(Color.accent).withAlphaComponent(0.85)
      case .shell:
        PlatformColor(Color.accent).withAlphaComponent(0.8)
      case .error:
        PlatformColor(Color.statusPermission)
    }
  }

  var glyphSymbol: String {
    switch messageType {
      case .user: "arrow.right"
      case .assistant: "sparkle"
      case .thinking: "brain.head.profile"
      case .steer: "arrow.turn.down.right"
      case .shell: "terminal"
      case .error: "exclamationmark.triangle.fill"
    }
  }

  var glyphColor: PlatformColor {
    switch messageType {
      case .user: PlatformColor(Color.accent).withAlphaComponent(0.7)
      case .assistant: PlatformColor.white.withAlphaComponent(0.85)
      case .thinking: PlatformColor.calibrated(red: 0.6, green: 0.55, blue: 0.8, alpha: 1)
      case .steer: PlatformColor(Color.accent)
      case .shell: PlatformColor(Color.shellAccent)
      case .error: PlatformColor(Color.statusPermission)
    }
  }

  var isUserAligned: Bool {
    messageType == .user || messageType == .shell
  }
}
