//
//  CodeViewport.swift
//  OrbitDock
//
//  Scrollable fixed-height code viewport for large content.
//  Renders only visible lines via LazyVStack, with edge fade gradients,
//  scroll position indicator, and "Expand to full" toggle.
//
//  Used by: ReadExpandedView, WriteExpandedView, EditExpandedView
//  Small content (≤30 lines) bypasses the viewport and renders inline.
//

import SwiftUI

struct CodeViewport<Content: View>: View {
  let lineCount: Int
  var maxHeight: CGFloat = defaultViewportHeight
  var accentColor: Color = .accent
  @ViewBuilder var content: () -> Content

  /// Threshold below which content renders inline (no viewport)
  private let inlineThreshold = 30

  /// Platform-adaptive default viewport height
  private static var defaultViewportHeight: CGFloat {
    #if os(iOS)
    260
    #else
    350
    #endif
  }

  @State private var isFullyExpanded = false

  var body: some View {
    if lineCount <= inlineThreshold || isFullyExpanded {
      inlineContent
    } else {
      viewportContent
    }
  }

  // MARK: - Inline (small content or user expanded)

  private var inlineContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      content()
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))

      if lineCount > inlineThreshold {
        collapseButton
      }
    }
  }

  // MARK: - Viewport (large content)

  private var viewportContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Scrollable viewport with edge fades
      ScrollView(.vertical, showsIndicators: false) {
        LazyVStack(alignment: .leading, spacing: 0) {
          content()
        }
      }
      .frame(maxHeight: maxHeight)
      .background(Color.backgroundCode)
      .mask(edgeFadeMask)
      .clipShape(
        UnevenRoundedRectangle(
          topLeadingRadius: Radius.sm, bottomLeadingRadius: 0,
          bottomTrailingRadius: 0, topTrailingRadius: Radius.sm
        )
      )

      // Footer bar
      footerBar
    }
  }

  // MARK: - Edge Fade Mask

  /// Gradient mask that fades content at top and bottom edges
  private var edgeFadeMask: some View {
    VStack(spacing: 0) {
      LinearGradient(
        colors: [.clear, .black],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: 10)

      Color.black

      LinearGradient(
        colors: [.black, .clear],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: 10)
    }
  }

  // MARK: - Footer Bar

  private var footerBar: some View {
    HStack(spacing: Spacing.sm) {
      Text("\(lineCount) lines")
        .font(.system(size: TypeScale.mini, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)

      Spacer()

      Button {
        withAnimation(Motion.standard) {
          isFullyExpanded = true
        }
      } label: {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8))
          Text("Expand to full")
            .font(.system(size: TypeScale.mini, weight: .medium))
        }
        .foregroundStyle(accentColor)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .background(Color.backgroundCode.opacity(0.7))
    .clipShape(
      UnevenRoundedRectangle(
        topLeadingRadius: 0, bottomLeadingRadius: Radius.sm,
        bottomTrailingRadius: Radius.sm, topTrailingRadius: 0
      )
    )
    .overlay(alignment: .top) {
      Rectangle()
        .fill(Color.textQuaternary.opacity(0.06))
        .frame(height: 1)
    }
  }

  // MARK: - Collapse Button

  private var collapseButton: some View {
    HStack {
      Spacer()
      Button {
        withAnimation(Motion.standard) {
          isFullyExpanded = false
        }
      } label: {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "arrow.down.right.and.arrow.up.left")
            .font(.system(size: 8))
          Text("Collapse to viewport")
            .font(.system(size: TypeScale.mini, weight: .medium))
        }
        .foregroundStyle(accentColor)
      }
      .buttonStyle(.plain)
    }
    .padding(.top, Spacing.xs)
  }
}
