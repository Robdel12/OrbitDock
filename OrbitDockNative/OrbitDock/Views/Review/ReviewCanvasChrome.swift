//
//  ReviewCanvasChrome.swift
//  OrbitDock
//
//  Toolbar and status chrome for the review canvas.
//

import SwiftUI

private struct ReviewCanvasToolbarView: View {
  let state: ReviewCanvasToolbarState
  let onToggleHistory: () -> Void
  let onToggleFollow: () -> Void

  var body: some View {
    HStack(spacing: Spacing.sm) {
      if let currentFileName = state.currentFileName {
        Text(currentFileName)
          .font(.system(size: TypeScale.body, weight: .semibold, design: .monospaced))
          .foregroundStyle(.primary.opacity(0.8))
          .lineLimit(1)
      }

      Spacer()

      if let history = state.history {
        Button(action: onToggleHistory) {
          HStack(spacing: Spacing.xs) {
            Image(systemName: history.iconName)
              .font(.system(size: TypeScale.micro, weight: .medium))
            Text(history.label)
              .font(.system(size: TypeScale.caption, weight: .medium))
          }
          .foregroundStyle(history.isVisible ? Color.statusQuestion : Color.white.opacity(0.3))
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)
          .background(
            history.isVisible ? Color.statusQuestion.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          )
        }
        .buttonStyle(.plain)
      }

      if let follow = state.follow {
        Button(action: onToggleFollow) {
          HStack(spacing: Spacing.xs) {
            Circle()
              .fill(follow.isFollowing ? Color.accent : Color.white.opacity(0.2))
              .frame(width: 5, height: 5)
            Text(follow.label)
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(follow.isFollowing ? Color.accent : Color.white.opacity(0.3))
          }
        }
        .buttonStyle(.plain)
      }

      HStack(spacing: Spacing.xs) {
        Text("+\(state.totalAdditions)")
          .foregroundStyle(Color.diffAddedAccent.opacity(0.8))
        Text("\u{2212}\(state.totalDeletions)")
          .foregroundStyle(Color.diffRemovedAccent.opacity(0.8))
      }
      .font(.system(size: TypeScale.caption, weight: .semibold, design: .monospaced))
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm_)
    .background(Color.backgroundSecondary)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.panelBorder)
        .frame(height: 1)
    }
  }
}

private struct ReviewCanvasSendReviewBarView: View {
  let state: ReviewSendBarState
  let onClearSelection: () -> Void
  let onSend: () -> Void

  var body: some View {
    HStack(spacing: Spacing.sm) {
      if state.hasSelection {
        Button(action: onClearSelection) {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "xmark")
              .font(.system(size: TypeScale.micro, weight: .bold))
            Text("\(state.selectedCommentCount) selected")
              .font(.system(size: TypeScale.caption, weight: .medium))
          }
          .foregroundStyle(.white.opacity(0.7))
          .padding(.horizontal, Spacing.md_)
          .padding(.vertical, Spacing.sm)
          .background(.white.opacity(OpacityTier.light), in: Capsule())
        }
        .buttonStyle(.plain)
      }

      Button(action: onSend) {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "paperplane.fill")
            .font(.system(size: TypeScale.body, weight: .medium))

          Text(state.label)
            .font(.system(size: TypeScale.code, weight: .semibold))

          Text("S")
            .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 5)
            .padding(.vertical, Spacing.xxs)
            .background(.white.opacity(OpacityTier.light), in: RoundedRectangle(cornerRadius: Radius.sm))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(Color.statusQuestion, in: Capsule())
        .themeShadow(Shadow.md)
      }
      .buttonStyle(.plain)
    }
    .padding(.bottom, Spacing.lg)
    .transition(.move(edge: .bottom).combined(with: .opacity))
    .animation(Motion.gentle, value: state.sendCount)
  }
}

private struct ReviewCanvasBannerView: View {
  let state: ReviewBannerState
  let onDismiss: () -> Void

  var body: some View {
    let accentColor = state.tone == .progress ? Color.accent : Color.statusQuestion

    HStack(spacing: 0) {
      Rectangle()
        .fill(accentColor)
        .frame(width: 3)

      HStack(spacing: Spacing.sm) {
        Image(systemName: state.iconName)
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(accentColor)

        Text(state.title)
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(.primary.opacity(OpacityTier.vivid))

        if let detail = state.detail {
          Text(detail)
            .font(.system(size: TypeScale.caption, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
        }

        Spacer()

        Button(action: onDismiss) {
          Image(systemName: "xmark")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.textQuaternary)
            .padding(Spacing.xs)
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
    }
    .background(accentColor.opacity(OpacityTier.tint))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(accentColor.opacity(OpacityTier.light))
        .frame(height: 1)
    }
    .transition(.asymmetric(
      insertion: .move(edge: .top).combined(with: .opacity),
      removal: .opacity
    ))
  }
}

extension ReviewCanvas {
  var toolbarState: ReviewCanvasToolbarState? {
    guard let model = diffModel else { return nil }
    return ReviewCanvasToolbarPlanner.toolbarState(
      currentFilePath: currentFile(model)?.newPath,
      model: model,
      hasResolvedComments: hasResolvedComments,
      showResolvedComments: showResolvedComments,
      isSessionActive: isSessionActive,
      isFollowing: isFollowing
    )
  }

  // MARK: - Full Layout Toolbar

  @ViewBuilder
  func fullLayoutToolbar(_ model: DiffModel) -> some View {
    if let toolbarState {
      ReviewCanvasToolbarView(
        state: toolbarState,
        onToggleHistory: {
          withAnimation(Motion.snappy) {
            showResolvedComments.toggle()
          }
        },
        onToggleFollow: {
          isFollowing.toggle()
          guard isFollowing else { return }
          if let lastFile = ReviewCursorNavigation.autoFollowFileHeaderIndex(
            isFollowing: true,
            isSessionActive: true,
            previousFileCount: 0,
            newFileCount: model.files.count,
            targets: visibleTargets(model)
          ) {
            cursorIndex = lastFile
          }
        }
      )
    }
  }

  @ViewBuilder
  var sendReviewBar: some View {
    if let reviewSendBarState {
      ReviewCanvasSendReviewBarView(
        state: reviewSendBarState,
        onClearSelection: {
          selectedCommentIds.removeAll()
        },
        onSend: sendReview
      )
    }
  }

  // MARK: - Review Banner

  @ViewBuilder
  var reviewBanner: some View {
    if let reviewBannerState {
      ReviewCanvasBannerView(
        state: reviewBannerState,
        onDismiss: {
          withAnimation(Motion.hover) {
            reviewRoundTracker.dismissBanner()
          }
        }
      )
    }
  }
}
