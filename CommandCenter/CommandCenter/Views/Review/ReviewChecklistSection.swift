//
//  ReviewChecklistSection.swift
//  OrbitDock
//
//  Review checklist content for the capability rail CollapsibleSection.
//  Shows all comments with filter, tag capsule, and click-to-navigate.
//

import SwiftUI

struct ReviewChecklistSection: View {
  let comments: [ServerReviewComment]
  let selectedIds: Set<String>
  let onNavigate: (ServerReviewComment) -> Void
  let onToggleSelection: (ServerReviewComment) -> Void
  var onSendReview: (() -> Void)? = nil

  @State private var showAll = false

  private var filtered: [ServerReviewComment] {
    if showAll { return comments }
    return comments.filter { $0.status == .open }
  }

  private var openCount: Int {
    comments.filter { $0.status == .open }.count
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Filter row
      HStack(spacing: 2) {
        filterButton("All", isSelected: showAll) { showAll = true }
        filterButton("Open", isSelected: !showAll) { showAll = false }
        Spacer()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)

      Divider()
        .foregroundStyle(Color.panelBorder.opacity(0.5))

      if filtered.isEmpty {
        HStack {
          Spacer()
          Text(showAll ? "No comments yet" : "No open comments")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
          Spacer()
        }
        .padding(.vertical, 16)
      } else {
        ForEach(filtered) { comment in
          HStack(spacing: 0) {
            // Selection toggle for open comments
            if comment.status == .open {
              Button {
                onToggleSelection(comment)
              } label: {
                Image(systemName: selectedIds.contains(comment.id)
                  ? "checkmark.circle.fill" : "circle")
                  .font(.system(size: 11))
                  .foregroundStyle(selectedIds.contains(comment.id)
                    ? Color.accent : Color.white.opacity(0.3))
              }
              .buttonStyle(.plain)
              .padding(.leading, 8)
            }

            commentRow(comment)
              .contentShape(Rectangle())
              .onTapGesture { onNavigate(comment) }
          }
        }
      }

      // Send Review button
      if openCount > 0, let onSendReview {
        let selectedCount = selectedIds.count
        let hasSelection = selectedCount > 0
        let sendLabel = hasSelection
          ? "Send \(selectedCount) Selected"
          : "Send Review (\(openCount))"

        Divider()
          .foregroundStyle(Color.panelBorder.opacity(0.5))

        Button(action: onSendReview) {
          HStack(spacing: 6) {
            Image(systemName: "paperplane.fill")
              .font(.system(size: 10, weight: .medium))
            Text(sendLabel)
              .font(.system(size: 11, weight: .semibold))
            Text("S")
              .font(.system(size: 9, weight: .bold, design: .monospaced))
              .foregroundStyle(Color.statusQuestion.opacity(0.6))
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(Color.statusQuestion.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
          }
          .foregroundStyle(Color.statusQuestion)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
      }
    }
    .background(Color.backgroundPrimary)
  }

  private func filterButton(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(label)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(isSelected ? Color.accent : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
          isSelected ? Color.accent.opacity(0.15) : Color.clear,
          in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
    }
    .buttonStyle(.plain)
  }

  private func commentRow(_ comment: ServerReviewComment) -> some View {
    let fileName = comment.filePath.components(separatedBy: "/").last ?? comment.filePath

    return HStack(spacing: 8) {
      // Status dot
      Circle()
        .fill(comment.status == .open ? Color.statusQuestion : Color.statusReady)
        .frame(width: 5, height: 5)

      VStack(alignment: .leading, spacing: 2) {
        // File + line
        HStack(spacing: 4) {
          Text(fileName)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.8))
            .lineLimit(1)

          Text(":\(comment.lineStart)")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
        }

        // Body preview
        Text(String(comment.body.prefix(50)))
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 0)

      // Tag capsule
      if let tag = comment.tag {
        Text(tag.rawValue)
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(Color.statusQuestion)
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(Color.statusQuestion.opacity(0.12), in: Capsule())
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color.backgroundPrimary)
  }
}
