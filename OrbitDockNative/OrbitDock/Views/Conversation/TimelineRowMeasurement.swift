//
//  TimelineRowMeasurement.swift
//  OrbitDock
//
//  Deterministic row height calculation for the conversation timeline.
//  Pure function: (entry, rowState, width) -> height.
//  Calls into existing native measurement code (markdown, code blocks, tables).
//

import SwiftUI

private let horizontalPad: CGFloat = Spacing.lg
private let userBubbleMaxWidth: CGFloat = 640

enum TimelineRowMeasurement {
  /// Compute the deterministic height for a given row entry at the given width.
  static func height(
    for entry: ServerConversationRowEntry,
    rowState: TimelineRowStateStore,
    width: CGFloat
  ) -> CGFloat {
    let contentWidth = max(100, width - horizontalPad * 2)
    switch entry.row {
    case let .user(msg):
      return userMessageHeight(msg, contentWidth: contentWidth)
    case let .assistant(msg):
      return assistantMessageHeight(msg, contentWidth: contentWidth)
    case let .system(msg):
      return systemMessageHeight(msg)
    case let .thinking(msg):
      return thinkingHeight(msg, isExpanded: rowState.isExpanded(msg.id), contentWidth: contentWidth)
    case let .tool(toolRow):
      return toolCardHeight(toolRow, isExpanded: rowState.isExpanded(toolRow.id),
                            fetchedContent: rowState.content(for: toolRow.id))
    case let .activityGroup(group):
      return activityGroupHeight(group, rowState: rowState)
    case .approval, .question:
      return approvalHeight(entry.row)
    case .worker, .plan, .hook, .handoff:
      return workerHeight(entry.row)
    }
  }

  // MARK: - Message Heights

  private static func userMessageHeight(_ msg: ServerConversationMessageRow, contentWidth: CGFloat) -> CGFloat {
    let bubbleMax = min(userBubbleMaxWidth, contentWidth)
    let bubbleContentWidth = bubbleMax - Spacing.lg_ * 2

    // Label "You"
    var total: CGFloat = labelLineHeight

    // Images
    if let images = msg.images, !images.isEmpty {
      total += Spacing.xs // spacing before images
      total += imageGridHeight(images, maxWidth: bubbleContentWidth)
    }

    // Markdown content
    if !msg.content.isEmpty {
      total += Spacing.xs // spacing before content
      total += markdownHeight(msg.content, style: .standard, width: bubbleContentWidth)
    }

    // Inner padding: .padding(.horizontal, Spacing.lg_) + .padding(.vertical, Spacing.md)
    total += Spacing.md * 2

    // Outer .padding(.vertical, Spacing.sm)
    total += Spacing.sm * 2

    return total
  }

  private static func assistantMessageHeight(_ msg: ServerConversationMessageRow, contentWidth: CGFloat) -> CGFloat {
    // Label "Assistant"
    var total: CGFloat = labelLineHeight

    // Images
    if let images = msg.images, !images.isEmpty {
      total += Spacing.xs
      total += imageGridHeight(images, maxWidth: contentWidth)
    }

    // Markdown content
    if !msg.content.isEmpty {
      total += Spacing.xs
      total += markdownHeight(msg.content, style: .standard, width: contentWidth)
    }

    // Streaming dots row
    if msg.isStreaming {
      total += Spacing.xs + 4 // dots are 4pt tall
    }

    // Inner .padding(.vertical, Spacing.md)
    total += Spacing.md * 2

    return total
  }

  private static func systemMessageHeight(_ msg: ServerConversationMessageRow) -> CGFloat {
    guard !msg.content.isEmpty else { return Spacing.xs * 2 }
    // System messages: single Text with TypeScale.caption + .padding(.vertical, Spacing.xs)
    let lineHeight = ceil(TypeScale.caption * 1.3)
    return lineHeight + Spacing.xs * 2
  }

  // MARK: - Thinking Height

  private static func thinkingHeight(
    _ msg: ServerConversationMessageRow,
    isExpanded: Bool,
    contentWidth: CGFloat
  ) -> CGFloat {
    // Header: chevron + "Reasoning" label + optional spinner
    var total: CGFloat = thinkingHeaderHeight

    if isExpanded, !msg.content.isEmpty {
      total += Spacing.xs // VStack spacing
      total += markdownHeight(msg.content, style: .thinking, width: contentWidth)
    }

    // Outer .padding(.vertical, Spacing.md)
    total += Spacing.md * 2

    return total
  }

  // MARK: - Tool Card Height

  private static func toolCardHeight(
    _ toolRow: ServerConversationToolRow,
    isExpanded: Bool,
    fetchedContent: ServerRowContent?
  ) -> CGFloat {
    let display = toolRow.toolDisplay
    var total: CGFloat = compactRowHeight(display)

    if !isExpanded {
      total += compactInlinePreviewHeight(display, isRunning: toolRow.status == .running || toolRow.status == .pending)
    }

    if isExpanded {
      // Divider: 1pt
      total += 1
      if fetchedContent != nil {
        // Expanded body + padding
        total += expandedBodyEstimate
      } else {
        // Loading indicator
        total += loadingIndicatorHeight
      }
    }

    // Outer .padding(.vertical, Spacing.xxs)
    total += Spacing.xxs * 2

    return total
  }

  private static func compactRowHeight(_ display: ServerToolDisplay?) -> CGFloat {
    // HStack with icon (16pt) + VStack(title + optional subtitle) + trailing items
    // .padding(.leading, Spacing.md + EdgeBar.width) .padding(.trailing, Spacing.md) .padding(.vertical, Spacing.sm_)
    let hasSubtitle = display?.subtitle != nil && display?.subtitleAbsorbsMeta != true
    let textHeight: CGFloat = hasSubtitle
      ? ceil(TypeScale.body * 1.3) + ceil(TypeScale.caption * 1.3)
      : ceil(TypeScale.body * 1.3)
    return max(16, textHeight) + Spacing.sm_ * 2
  }

  private static func compactInlinePreviewHeight(_ display: ServerToolDisplay?, isRunning: Bool) -> CGFloat {
    guard let display else { return 0 }
    var total: CGFloat = 0

    // Diff preview strip
    if display.diffPreview != nil {
      total += previewStripHeight
    }

    // Live output strip (running bash)
    if isRunning, let live = display.liveOutputPreview, !live.isEmpty {
      total += previewStripHeight
    }

    // Output preview strip (completed)
    if !isRunning, let preview = display.outputPreview, !preview.isEmpty {
      total += previewStripHeight
    }

    // Todo preview strip
    if !display.todoItems.isEmpty {
      total += previewStripHeight
    }

    return total
  }

  // MARK: - Activity Group Height

  private static func activityGroupHeight(
    _ group: ServerConversationActivityGroupRow,
    rowState: TimelineRowStateStore
  ) -> CGFloat {
    var total = activityGroupHeaderHeight

    if rowState.isExpanded(group.id) {
      total += Spacing.xs // .padding(.top, Spacing.xs)
      for (index, child) in group.children.enumerated() {
        if index > 0 { total += Spacing.xxs } // VStack spacing: N-1 gaps, not N
        total += toolCardHeight(child, isExpanded: rowState.isExpanded(child.id),
                                fetchedContent: rowState.content(for: child.id))
      }
    }

    // Outer .padding(.vertical, Spacing.xxs)
    total += Spacing.xxs * 2

    return total
  }

  // MARK: - Approval Height

  private static func approvalHeight(_ row: ServerConversationRow) -> CGFloat {
    let (_, subtitle, summary): (String, String?, String?)
    switch row {
    case let .approval(a): (_, subtitle, summary) = (a.title, a.subtitle, a.summary)
    case let .question(q): (_, subtitle, summary) = (q.title, q.subtitle, q.summary)
    default: return 60
    }

    // Icon (IconScale.xl = 12) + VStack(title + optional subtitle + optional summary)
    var textHeight = ceil(TypeScale.subhead * 1.4) // title
    if let subtitle, !subtitle.isEmpty {
      textHeight += Spacing.xs + ceil(TypeScale.body * 1.3) // subtitle
    }
    if let summary, !summary.isEmpty {
      textHeight += Spacing.xs + ceil(TypeScale.code * 1.3) // summary (monospaced)
    }

    let contentHeight = max(IconScale.xl, textHeight)

    // Inner .padding(Spacing.md) + outer .padding(.vertical, Spacing.xs)
    return contentHeight + Spacing.md * 2 + Spacing.xs * 2
  }

  // MARK: - Worker Height

  private static func workerHeight(_ row: ServerConversationRow) -> CGFloat {
    let hasSubtitle: Bool
    switch row {
    case let .worker(w): hasSubtitle = w.subtitle != nil && !w.subtitle!.isEmpty
    case let .plan(p): hasSubtitle = p.subtitle != nil && !p.subtitle!.isEmpty
    case let .hook(h): hasSubtitle = h.subtitle != nil && !h.subtitle!.isEmpty
    case let .handoff(h): hasSubtitle = h.subtitle != nil && !h.subtitle!.isEmpty
    default: return 36
    }

    let textHeight: CGFloat = hasSubtitle
      ? ceil(TypeScale.body * 1.3) + Spacing.xxs + ceil(TypeScale.caption * 1.3)
      : ceil(TypeScale.body * 1.3)

    // Icon frame (IconScale.lg) + .padding(.vertical, Spacing.sm)
    return max(IconScale.lg, textHeight) + Spacing.sm * 2
  }

  // MARK: - Shared Helpers

  private static func markdownHeight(_ content: String, style: ContentStyle, width: CGFloat) -> CGFloat {
    let blocks = MarkdownSystemParser.parse(content, style: style)
    return NativeMarkdownContentView.requiredHeight(for: blocks, width: width, style: style)
  }

  private static func imageGridHeight(_ images: [ServerImageInput], maxWidth: CGFloat) -> CGFloat {
    let maxThumbHeight: CGFloat = 240
    if images.count == 1 {
      return thumbnailHeight(images[0], maxWidth: maxWidth, maxHeight: maxThumbHeight)
    }
    // 2-column grid — take max of each row pair
    let colWidth = (maxWidth - Spacing.sm) / 2
    var total: CGFloat = 0
    for i in stride(from: 0, to: images.count, by: 2) {
      let h1 = thumbnailHeight(images[i], maxWidth: colWidth, maxHeight: maxThumbHeight)
      let h2 = i + 1 < images.count
        ? thumbnailHeight(images[i + 1], maxWidth: colWidth, maxHeight: maxThumbHeight)
        : 0
      total += max(h1, h2)
      if i + 2 < images.count { total += Spacing.sm }
    }
    return total
  }

  private static func thumbnailHeight(_ image: ServerImageInput, maxWidth: CGFloat, maxHeight: CGFloat) -> CGFloat {
    guard let w = image.pixelWidth, let h = image.pixelHeight, w > 0, h > 0 else {
      return 120 // default placeholder
    }
    let aspect = CGFloat(h) / CGFloat(w)
    return min(maxHeight, maxWidth * aspect)
  }

  // MARK: - Layout Constants

  /// Height of a role label line ("You", "Assistant", "Reasoning")
  private static let labelLineHeight: CGFloat = ceil(TypeScale.chatLabel * 1.4)

  /// Thinking header: chevron + "Reasoning" text
  private static let thinkingHeaderHeight: CGFloat = ceil(TypeScale.chatLabel * 1.4)

  /// Activity group collapsed header
  private static let activityGroupHeaderHeight: CGFloat = Spacing.sm_ * 2 + ceil(TypeScale.caption * 1.4)

  /// Preview strip height (diff, output, live, todo)
  private static let previewStripHeight: CGFloat = ceil(TypeScale.meta * 1.3) + Spacing.sm_

  /// Loading indicator height (ProgressView + "Loading…")
  private static let loadingIndicatorHeight: CGFloat = Spacing.md * 2 + ceil(TypeScale.caption * 1.3)

  /// Conservative estimate for expanded tool body.
  /// This is a fallback — expanded content varies widely by tool type.
  /// Phase 4 will add per-type measurement.
  private static let expandedBodyEstimate: CGFloat = 200
}
