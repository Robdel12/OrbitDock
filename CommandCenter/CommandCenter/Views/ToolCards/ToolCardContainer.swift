//
//  ToolCardContainer.swift
//  CommandCenter
//
//  Reusable container for tool cards with consistent styling
//

import SwiftUI

struct ToolCardContainer<Header: View, Content: View>: View {
    let color: Color
    let header: Header
    let content: Content?
    let isExpanded: Bool

    init(
        color: Color,
        isExpanded: Bool = false,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.color = color
        self.isExpanded = isExpanded
        self.header = header()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with accent bar
            HStack(spacing: 0) {
                Rectangle()
                    .fill(color)
                    .frame(width: 4)

                header
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .background(Color.backgroundTertiary.opacity(0.5))

            // Expandable content
            if isExpanded, let content = content {
                content
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.backgroundTertiary.opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(color.opacity(0.2), lineWidth: 1)
        )
    }
}

// Convenience init without content
extension ToolCardContainer where Content == EmptyView {
    init(
        color: Color,
        @ViewBuilder header: () -> Header
    ) {
        self.color = color
        self.isExpanded = false
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
        if let color = color {
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
        if let duration = duration {
            Text(duration)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }
}
