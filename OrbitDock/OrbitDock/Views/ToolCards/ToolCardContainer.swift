//
//  ToolCardContainer.swift
//  OrbitDock
//
//  Reusable container for tool cards with consistent styling
//

import SwiftUI
#if os(macOS)
  import AppKit
#endif

struct ToolCardContainer<Header: View, Content: View>: View {
  let color: Color
  let header: Header
  let content: Content?
  @Binding var isExpanded: Bool
  let hasContent: Bool
  @State private var isHovering = false

  init(
    color: Color,
    isExpanded: Binding<Bool>,
    hasContent: Bool = true,
    @ViewBuilder header: () -> Header,
    @ViewBuilder content: () -> Content
  ) {
    self.color = color
    self._isExpanded = isExpanded
    self.hasContent = hasContent
    self.header = header()
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header with accent bar - tappable to expand
      HStack(spacing: 0) {
        Rectangle()
          .fill(color)
          .frame(width: EdgeBar.width)

        header
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, Spacing.sm)

        Spacer(minLength: 0)
      }
      .background(isHovering && hasContent ? Color.surfaceHover : Color.backgroundTertiary.opacity(0.5))
      .contentShape(Rectangle())
      .onHover { hovering in
        isHovering = hovering
        #if os(macOS)
          if hasContent {
            if hovering {
              NSCursor.pointingHand.push()
            } else {
              NSCursor.pop()
            }
          }
        #endif
      }
      .onTapGesture {
        if hasContent {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            isExpanded.toggle()
          }
        }
      }

      // Expandable content
      if isExpanded, let content {
        content
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.backgroundTertiary.opacity(0.3))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .strokeBorder(color.opacity(isHovering ? OpacityTier.strong : OpacityTier.medium), lineWidth: 1)
    )
  }
}

/// Convenience init without content
extension ToolCardContainer where Content == EmptyView {
  init(
    color: Color,
    @ViewBuilder header: () -> Header
  ) {
    self.color = color
    self._isExpanded = .constant(false)
    self.hasContent = false
    self.header = header()
    self.content = nil
  }
}

// MARK: - Expand Button

struct ToolCardExpandButton: View {
  @Binding var isExpanded: Bool

  var body: some View {
    Button {
      withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
        isExpanded.toggle()
      }
    } label: {
      Image(systemName: "chevron.right")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.tertiary)
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Stats Badge

struct ToolCardStatsBadge: View {
  let text: String
  let color: Color?

  init(_ text: String, color: Color? = nil) {
    self.text = text
    self.color = color
  }

  var body: some View {
    if let color {
      Text(text)
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    } else {
      Text(text)
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Duration Badge

struct ToolCardDuration: View {
  let duration: String?

  var body: some View {
    if let duration {
      Text(duration)
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.tertiary)
    }
  }
}
