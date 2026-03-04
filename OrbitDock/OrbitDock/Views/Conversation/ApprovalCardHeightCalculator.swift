//
//  ApprovalCardHeightCalculator.swift
//  OrbitDock
//
//  Cross-platform height calculation for approval cards.
//  Uses PlatformFont so the same logic compiles on macOS (NSFont) and iOS (UIFont).
//

import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

enum ApprovalCardHeightCalculator {

  // MARK: - Platform Layout Constants

  enum Layout {
    static let outerVerticalInset: CGFloat = 6
    static let commandVerticalPadding: CGFloat = 6
    static let commandHorizontalPadding: CGFloat = 10
    static let maxCommandTextHeight: CGFloat = 220

    // Platform-specific touch targets
    #if os(macOS)
      static let cardPadding: CGFloat = 12
      static let headerIconSize: CGFloat = 14
      static let primaryButtonHeight: CGFloat = 32
      static let answerFieldHeight: CGFloat = 26
      static let submitButtonHeight: CGFloat = 28
      static let takeoverButtonHeight: CGFloat = 30
      static let questionOptionMinHeight: CGFloat = 44
      static let questionOptionTextInset: CGFloat = 24
      static let questionOptionVerticalPadding: CGFloat = 14
      static let questionPromptSectionInset: CGFloat = 10
      static let questionPromptSectionSpacing: CGFloat = 8
      static let questionMaxContentWidth: CGFloat = 980
    #else
      static let cardPadding: CGFloat = 14
      static let headerIconSize: CGFloat = 15
      static let primaryButtonHeight: CGFloat = 44
      static let answerFieldHeight: CGFloat = 34
      static let submitButtonHeight: CGFloat = 42
      static let takeoverButtonHeight: CGFloat = 42
      static let questionOptionMinHeight: CGFloat = 52
      static let questionOptionTextInset: CGFloat = 24
      static let questionOptionVerticalPadding: CGFloat = 16
      static let questionPromptSectionInset: CGFloat = 10
      static let questionPromptSectionSpacing: CGFloat = 8
      static let questionMaxContentWidth: CGFloat = 860
    #endif
  }

  // MARK: - Public API

  static func requiredHeight(for model: ApprovalCardModel?, availableWidth: CGFloat) -> CGFloat {
    guard let model else {
      #if os(macOS)
        return 120
      #else
        return 140
      #endif
    }

    let laneInset = ConversationLayout.laneHorizontalInset
    let contentWidth = availableWidth - laneInset * 2 - Layout.cardPadding * 2

    switch model.mode {
      case .permission:
        return permissionHeight(model, contentWidth: contentWidth)
      case .question:
        return questionHeight(model, contentWidth: contentWidth)
      case .takeover:
        return takeoverHeight()
      case .none:
        return 1
    }
  }

  // MARK: - Mode-specific Height

  private static func permissionHeight(_ model: ApprovalCardModel, contentWidth: CGFloat) -> CGFloat {
    let pad = Layout.cardPadding
    let outerInset = Layout.outerVerticalInset

    var h: CGFloat = outerInset
    h += 2 // risk strip
    h += pad // top card padding
    h += Layout.headerIconSize // merged header row

    let hasContent = ApprovalPermissionPreviewHelpers.hasPreviewContent(model)
    if hasContent {
      h += CGFloat(Spacing.sm)
      h += segmentStackHeight(for: model, contentWidth: contentWidth)
    }

    if !model.riskFindings.isEmpty {
      h += CGFloat(Spacing.sm)
      let findingHeight: CGFloat = 14
      h += findingHeight * CGFloat(model.riskFindings.count)
      h += CGFloat(Spacing.xs) * CGFloat(max(0, model.riskFindings.count - 1))
    }

    h += CGFloat(Spacing.md) // spacing before buttons
    h += Layout.primaryButtonHeight
    h += pad // bottom card padding
    h += outerInset
    return h
  }

  private static func questionHeight(_ model: ApprovalCardModel, contentWidth: CGFloat) -> CGFloat {
    let pad = Layout.cardPadding
    let outerInset = Layout.outerVerticalInset
    let questionContentWidth = min(contentWidth, Layout.questionMaxContentWidth)

    var h: CGFloat = outerInset + 2 + pad // cell pad + risk strip + card pad
    h += Layout.headerIconSize // header

    let prompts = model.questions
    if prompts.count > 1 {
      h += CGFloat(Spacing.sm)
      for (index, prompt) in prompts.enumerated() {
        h += questionPromptSectionHeight(prompt, width: questionContentWidth)
        if index < prompts.count - 1 {
          h += CGFloat(Spacing.xs)
        }
      }
      h += CGFloat(Spacing.md) + Layout.submitButtonHeight
    } else if let prompt = prompts.first {
      h += CGFloat(Spacing.md)
      let hasOptions = !prompt.options.isEmpty
      let requiresSubmit = prompt.allowsOther || prompt.allowsMultipleSelection
      let headingText = hasOptions ? "Choose Your Response" : prompt.question
      let headingFont = PlatformFont.systemFont(
        ofSize: hasOptions ? TypeScale.reading : TypeScale.reading,
        weight: hasOptions ? .semibold : .regular
      )
      h += measureTextHeight(headingText, font: headingFont, width: questionContentWidth)
      h += 4
      let captionText: String = if !hasOptions {
        "Type a quick response and submit."
      } else if requiresSubmit {
        prompt.allowsMultipleSelection
          ? "Pick the options that apply, then submit."
          : "Pick an option or type your own response, then submit."
      } else {
        "Choose one option to continue."
      }
      h += measureTextHeight(
        captionText,
        font: PlatformFont.systemFont(ofSize: TypeScale.body, weight: .regular),
        width: questionContentWidth
      )
      if !hasOptions {
        h += CGFloat(Spacing.md) + Layout.answerFieldHeight
        h += CGFloat(Spacing.md) + Layout.submitButtonHeight
      } else {
        h += CGFloat(Spacing.md) + questionPromptSectionHeight(prompt, width: questionContentWidth)
        if requiresSubmit {
          h += CGFloat(Spacing.md) + Layout.submitButtonHeight
        }
      }
    } else {
      h += CGFloat(Spacing.md)
      h += 20
      h += CGFloat(Spacing.md) + Layout.answerFieldHeight
      h += CGFloat(Spacing.md) + Layout.submitButtonHeight
    }

    h += pad + outerInset
    return h
  }

  private static func takeoverHeight() -> CGFloat {
    let pad = Layout.cardPadding
    let outerInset = Layout.outerVerticalInset

    var h: CGFloat = outerInset + 2 + pad
    h += Layout.headerIconSize // header
    h += CGFloat(Spacing.md) + 20 // description
    h += CGFloat(Spacing.md) + Layout.takeoverButtonHeight
    h += pad + outerInset
    return h
  }

  // MARK: - Segment Stack

  static func segmentStackHeight(for model: ApprovalCardModel, contentWidth: CGFloat) -> CGFloat {
    let textWidth = max(1, contentWidth - CGFloat(EdgeBar.width) - Layout.commandHorizontalPadding * 2)
    let monoFont = PlatformFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .regular)

    var segments: [(command: String, hasOperator: Bool)] = []

    switch model.previewType {
      case .shellCommand:
        if !model.shellSegments.isEmpty {
          segments = model.shellSegments.map { ($0.command, $0.leadingOperator != nil) }
        } else if let cmd = ApprovalPermissionPreviewHelpers.trimmed(model.command) {
          segments = [(cmd, false)]
        } else if let manifest = ApprovalPermissionPreviewHelpers.trimmed(model.serverManifest) {
          segments = [(manifest, false)]
        }
      default:
        if let value = ApprovalPermissionPreviewHelpers.previewValue(for: model) {
          let labelHeight: CGFloat = 12
          let textHeight = measureTextHeight(value, font: monoFont, width: textWidth)
          let clampedText = min(textHeight, Layout.maxCommandTextHeight)
          return Layout.commandVerticalPadding + labelHeight + CGFloat(Spacing.xxs)
            + clampedText + Layout.commandVerticalPadding
        } else if let manifest = ApprovalPermissionPreviewHelpers.trimmed(model.serverManifest) {
          segments = [(manifest, false)]
        }
    }

    guard !segments.isEmpty else { return 0 }

    var total: CGFloat = 0
    for (index, segment) in segments.enumerated() {
      let textHeight = measureTextHeight(segment.command, font: monoFont, width: textWidth)
      let clampedText = min(textHeight, Layout.maxCommandTextHeight)
      var segmentHeight = Layout.commandVerticalPadding + clampedText + Layout.commandVerticalPadding
      if segment.hasOperator {
        segmentHeight += 16 + CGFloat(Spacing.xs)
      }
      total += segmentHeight
      if index > 0 {
        total += CGFloat(Spacing.xs)
      }
    }
    return total
  }

  // MARK: - Question Helpers

  private static func questionPromptSectionHeight(_ prompt: ApprovalQuestionPrompt, width: CGFloat) -> CGFloat {
    let sectionContentWidth = max(1, width - 34)
    var components: [CGFloat] = []

    components.append(16)
    let trimmedHeader = prompt.header?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmedHeader.isEmpty {
      components.append(
        measureTextHeight(
          trimmedHeader.uppercased(),
          font: PlatformFont.systemFont(ofSize: TypeScale.caption, weight: .semibold),
          width: sectionContentWidth
        )
      )
    }
    let questionHeight = measureTextHeight(
      prompt.question,
      font: PlatformFont.systemFont(ofSize: TypeScale.reading, weight: .semibold),
      width: sectionContentWidth
    )
    components.append(questionHeight)

    if !prompt.options.isEmpty {
      var optionsHeight: CGFloat = 0
      let optionGap = CGFloat(Spacing.sm_)
      for (index, option) in prompt.options.enumerated() {
        optionsHeight += questionOptionHeight(option, width: sectionContentWidth)
        if index < prompt.options.count - 1 {
          optionsHeight += optionGap
        }
      }
      components.append(optionsHeight)
    }

    if prompt.options.isEmpty || prompt.allowsOther {
      components.append(Layout.answerFieldHeight)
    }

    let componentSpacing =
      max(0, CGFloat(components.count - 1)) * Layout.questionPromptSectionSpacing
    let contentHeight = components.reduce(0, +) + componentSpacing
    return contentHeight + 16
  }

  private static func questionOptionHeight(_ option: ApprovalQuestionOption, width: CGFloat) -> CGFloat {
    let textWidth = max(1, width - Layout.questionOptionTextInset)
    let titleHeight = measureTextHeight(
      option.label,
      font: PlatformFont.systemFont(ofSize: TypeScale.body, weight: .semibold),
      width: textWidth
    )
    var contentHeight = titleHeight
    if let description = option.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
      contentHeight += CGFloat(Spacing.xxs)
      contentHeight += measureTextHeight(
        description,
        font: PlatformFont.systemFont(ofSize: TypeScale.caption, weight: .regular),
        width: textWidth
      )
    }
    contentHeight += Layout.questionOptionVerticalPadding
    return max(Layout.questionOptionMinHeight, contentHeight)
  }

  // MARK: - Text Measurement

  static func measureTextHeight(_ text: String, font: PlatformFont, width: CGFloat) -> CGFloat {
    guard !text.isEmpty, width > 0 else { return 0 }
    let attr = NSAttributedString(string: text, attributes: [.font: font])
    #if os(macOS)
      let rect = attr.boundingRect(
        with: NSSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
      )
    #else
      let rect = attr.boundingRect(
        with: CGSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        context: nil
      )
    #endif
    return ceil(rect.height)
  }
}
