//
//  ReviewCanvasChrome.swift
//  OrbitDock
//
//  Toolbar and status chrome for the review canvas.
//

import SwiftUI

extension ReviewCanvas {
  // MARK: - Full Layout Toolbar

  func fullLayoutToolbar(_ model: DiffModel) -> some View {
    let totalAdds = model.files.reduce(0) { $0 + $1.stats.additions }
    let totalDels = model.files.reduce(0) { $0 + $1.stats.deletions }

    return HStack(spacing: Spacing.sm) {
      if let file = currentFile(model) {
        let fileName = file.newPath.components(separatedBy: "/").last ?? file.newPath
        Text(fileName)
          .font(.system(size: TypeScale.body, weight: .semibold, design: .monospaced))
          .foregroundStyle(.primary.opacity(0.8))
          .lineLimit(1)
      }

      Spacer()

      if hasResolvedComments {
        Button {
          withAnimation(Motion.snappy) {
            showResolvedComments.toggle()
          }
        } label: {
          HStack(spacing: Spacing.xs) {
            Image(systemName: showResolvedComments ? "eye.fill" : "eye.slash")
              .font(.system(size: TypeScale.micro, weight: .medium))
            Text("History")
              .font(.system(size: TypeScale.caption, weight: .medium))
          }
          .foregroundStyle(showResolvedComments ? Color.statusQuestion : Color.white.opacity(0.3))
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)
          .background(
            showResolvedComments ? Color.statusQuestion.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          )
        }
        .buttonStyle(.plain)
      }

      if isSessionActive {
        Button {
          isFollowing.toggle()
          if isFollowing,
             let lastFile = ReviewCursorNavigation.autoFollowFileHeaderIndex(
               isFollowing: true,
               isSessionActive: true,
               previousFileCount: 0,
               newFileCount: model.files.count,
               targets: visibleTargets(model)
             )
          {
            cursorIndex = lastFile
          }
        } label: {
          HStack(spacing: Spacing.xs) {
            Circle()
              .fill(isFollowing ? Color.accent : Color.white.opacity(0.2))
              .frame(width: 5, height: 5)
            Text(isFollowing ? "Following" : "Paused")
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(isFollowing ? Color.accent : Color.white.opacity(0.3))
          }
        }
        .buttonStyle(.plain)
      }

      HStack(spacing: Spacing.xs) {
        Text("+\(totalAdds)")
          .foregroundStyle(Color.diffAddedAccent.opacity(0.8))
        Text("\u{2212}\(totalDels)")
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

  @ViewBuilder
  var sendReviewBar: some View {
    if let reviewSendBarState {
      HStack(spacing: Spacing.sm) {
        if reviewSendBarState.hasSelection {
          Button {
            selectedCommentIds.removeAll()
          } label: {
            HStack(spacing: Spacing.xs) {
              Image(systemName: "xmark")
                .font(.system(size: TypeScale.micro, weight: .bold))
              Text("\(reviewSendBarState.selectedCommentCount) selected")
                .font(.system(size: TypeScale.caption, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, Spacing.md_)
            .padding(.vertical, Spacing.sm)
            .background(.white.opacity(OpacityTier.light), in: Capsule())
          }
          .buttonStyle(.plain)
        }

        Button(action: sendReview) {
          HStack(spacing: Spacing.sm) {
            Image(systemName: "paperplane.fill")
              .font(.system(size: TypeScale.body, weight: .medium))

            Text(reviewSendBarState.label)
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
      .animation(Motion.gentle, value: reviewSendBarState.sendCount)
    }
  }

  // MARK: - Review Banner

  @ViewBuilder
  var reviewBanner: some View {
    if let reviewBannerState {
      let accentColor = reviewBannerState.tone == .progress ? Color.accent : Color.statusQuestion

      HStack(spacing: 0) {
        Rectangle()
          .fill(accentColor)
          .frame(width: 3)

        HStack(spacing: Spacing.sm) {
          Image(systemName: reviewBannerState.iconName)
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(accentColor)

          Text(reviewBannerState.title)
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(.primary.opacity(OpacityTier.vivid))

          if let detail = reviewBannerState.detail {
            Text(detail)
              .font(.system(size: TypeScale.caption, design: .monospaced))
              .foregroundStyle(Color.textTertiary)
          }

          Spacer()

          Button {
            withAnimation(Motion.hover) {
              reviewRoundTracker.dismissBanner()
            }
          } label: {
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
}
