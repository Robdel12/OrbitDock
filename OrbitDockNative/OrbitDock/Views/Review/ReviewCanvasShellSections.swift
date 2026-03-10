import SwiftUI

extension ReviewCanvas {
  // MARK: - Full Layout

  func fullLayout(_ model: DiffModel) -> some View {
    HStack(spacing: 0) {
      FileListNavigator(
        files: model.files,
        turnDiffs: obs.turnDiffs,
        selectedFileId: fileListBinding(model),
        selectedTurnDiffId: $selectedTurnDiffId,
        commentCounts: commentCounts,
        addressedFiles: addressedFilePaths,
        reviewPendingFiles: reviewedFilePaths.subtracting(addressedFilePaths),
        showResolvedComments: $showResolvedComments,
        hasResolvedComments: hasResolvedComments
      )

      Divider()
        .foregroundStyle(Color.panelBorder)

      VStack(spacing: 0) {
        fullLayoutToolbar(model)
        unifiedDiffView(model)
      }
    }
  }

  // MARK: - Compact Layout

  func compactLayout(_ model: DiffModel) -> some View {
    VStack(spacing: 0) {
      compactFileStrip(model)
      unifiedDiffView(model)
    }
  }

  // MARK: - Unified Diff View

  func unifiedDiffView(_ model: DiffModel) -> some View {
    let targets = visibleTargets(model)
    let safeIdx = targets.isEmpty ? 0 : min(cursorIndex, targets.count - 1)
    let target = targets.isEmpty ? nil : targets[safeIdx]

    return ScrollViewReader { proxy in
      ScrollView(.vertical, showsIndicators: true) {
        ReviewCanvasDiffFiles(
          model: model,
          target: target,
          reviewComments: obs.reviewComments,
          selectedTurnDiffId: selectedTurnDiffId,
          showResolvedComments: showResolvedComments,
          selectedCommentIds: $selectedCommentIds,
          commentInteraction: $commentInteraction,
          collapsedFiles: $collapsedFiles,
          collapsedHunks: $collapsedHunks,
          expandedContextBars: $expandedContextBars,
          reviewBanner: {
            reviewBanner
          },
          fileHeader: { file, fileIndex, isCursor in
            fileSectionHeader(file: file, fileIndex: fileIndex, isCursor: isCursor)
          },
          onSelectFileHeader: { fileIndex in
            isFollowing = false
            if let index = targets.firstIndex(of: .fileHeader(fileIndex: fileIndex)) {
              cursorIndex = index
            }
          },
          onToggleFileCollapse: { fileIndex in
            toggleCollapseAtCursor(model: model, fileIdx: fileIndex)
          },
          onToggleHunkCollapse: { fileIndex, hunkIndex in
            toggleHunkCollapse(model: model, fileIdx: fileIndex, hunkIdx: hunkIndex)
          },
          mouseSelectionLineIndices: { fileIndex, hunkIndex in
            mouseSelectionLineIndices(fileIdx: fileIndex, hunkIdx: hunkIndex)
          },
          selectionLineIndices: { fileIndex, hunkIndex in
            selectionLineIndices(fileIdx: fileIndex, hunkIdx: hunkIndex)
          },
          composerLineRangeForHunk: { fileIndex, hunkIndex in
            composerLineRangeForHunk(fileIdx: fileIndex, hunkIdx: hunkIndex)
          },
          onLineComment: { fileIndex, hunkIndex, clickedLineIndex, smartRange in
            handleLineComment(
              fileIdx: fileIndex,
              hunkIdx: hunkIndex,
              clickedIdx: clickedLineIndex,
              smartRange: smartRange,
              model: model
            )
          },
          onLineDragChanged: { fileIndex, hunkIndex, anchor, current in
            handleLineDragChanged(fileIdx: fileIndex, hunkIdx: hunkIndex, anchor: anchor, current: current)
          },
          onLineDragEnded: { fileIndex, hunkIndex, startIndex, endIndex in
            handleLineDragEnded(
              fileIdx: fileIndex,
              hunkIdx: hunkIndex,
              startIdx: startIndex,
              endIdx: endIndex,
              model: model
            )
          },
          onSubmitComment: {
            submitComment()
          },
          onResolveComment: { comment in
            resolveComment(comment)
          }
        )
      }
      .onChange(of: cursorIndex) { _, newIdx in
        let currentTargets = visibleTargets(model)
        guard !currentTargets.isEmpty else { return }
        let safe = min(newIdx, currentTargets.count - 1)
        withAnimation(Motion.snappy) {
          proxy.scrollTo(currentTargets[safe].scrollId, anchor: .center)
        }
      }
    }
    .focusable()
    .focused($isCanvasFocused)
    .onKeyPress(keys: [.escape]) { _ in
      commentInteraction.cancelActiveInteraction()
      return .handled
    }
    .onKeyPress(keys: [.tab]) { _ in
      guard !commentInteraction.hasComposer else { return .ignored }
      let currentTarget = currentTarget(model)
      switch currentTarget {
        case let .fileHeader(fileIndex):
          toggleCollapseAtCursor(model: model, fileIdx: fileIndex)
        case let .hunkHeader(fileIndex, hunkIndex):
          toggleHunkCollapse(model: model, fileIdx: fileIndex, hunkIdx: hunkIndex)
        case let .diffLine(fileIndex, hunkIndex, _):
          toggleHunkCollapse(model: model, fileIdx: fileIndex, hunkIdx: hunkIndex)
        case nil:
          break
      }
      return .handled
    }
    .onKeyPress(keys: [.return]) { _ in
      guard !commentInteraction.hasComposer, let file = currentFile(model) else { return .ignored }
      openFileInEditor(file)
      return .handled
    }
    .onKeyPress { keyPress in
      guard !commentInteraction.hasComposer else { return .ignored }
      return handleKeyPress(keyPress, model: model)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .bottom) {
      if reviewSendBarState != nil {
        sendReviewBar
      }
    }
  }
}
