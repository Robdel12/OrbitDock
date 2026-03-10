import CoreGraphics
import Foundation

struct DirectSessionComposerPendingPresentation {
  let title: String
  let statusText: String
  let promptCountText: String?
  let fallbackHeight: CGFloat
  let clampedContentHeight: CGFloat
  let previewText: String
  let commandChainSegments: [ApprovalShellSegment]

  var showsCommandChain: Bool {
    !commandChainSegments.isEmpty
  }
}

struct DirectSessionComposerPendingQuestionContentState {
  let activeIndex: Int
  let prompts: [ApprovalQuestionPrompt]

  var activePrompt: ApprovalQuestionPrompt? {
    guard activeIndex >= 0, activeIndex < prompts.count else { return nil }
    return prompts[activeIndex]
  }
}

extension DirectSessionComposerPendingPlanner {
  static func presentation(
    for model: ApprovalCardModel,
    showsDenyReason: Bool,
    measuredHeight: CGFloat,
    maxHeight: CGFloat
  ) -> DirectSessionComposerPendingPresentation {
    let fallbackHeight = fallbackContentHeight(for: model, showsDenyReason: showsDenyReason)
    let clampedContentHeight = clampedContentHeight(
      measuredHeight: measuredHeight,
      maxHeight: maxHeight,
      fallbackHeight: fallbackHeight
    )

    let previewText = model.command ?? model.filePath ?? "Review required before the session can continue."
    let commandChainSegments: [ApprovalShellSegment] = {
      guard model.previewType == .shellCommand else { return [] }
      if !model.shellSegments.isEmpty { return model.shellSegments }
      if let command = model.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
        return [ApprovalShellSegment(command: command, leadingOperator: nil)]
      }
      return []
    }()

    return DirectSessionComposerPendingPresentation(
      title: title(for: model),
      statusText: statusBadgeText(for: model),
      promptCountText: model.mode == .question && model.questions.count > 1 ? "\(model.questions.count) prompts" : nil,
      fallbackHeight: fallbackHeight,
      clampedContentHeight: clampedContentHeight,
      previewText: previewText,
      commandChainSegments: commandChainSegments
    )
  }

  static func questionContentState(
    prompts: [ApprovalQuestionPrompt],
    promptIndex: Int
  ) -> DirectSessionComposerPendingQuestionContentState {
    let boundedIndex = min(max(promptIndex, 0), max(0, prompts.count - 1))
    return DirectSessionComposerPendingQuestionContentState(
      activeIndex: boundedIndex,
      prompts: prompts
    )
  }
}
