//
//  TodoExpandedView.swift
//  OrbitDock
//
//  Todo list expanded view with progress bar and item status.
//

import SwiftUI

struct TodoExpandedView: View {
  let content: ServerRowContent
  let display: ServerToolDisplay?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if let display, !display.todoItems.isEmpty {
        let completed = display.todoItems.filter { $0.status == "completed" }.count
        let total = display.todoItems.count

        // Progress bar
        ProgressSummaryBar(completed: completed, total: total)

        // Todo items
        VStack(alignment: .leading, spacing: Spacing.xs) {
          ForEach(Array(display.todoItems.enumerated()), id: \.offset) { _, item in
            todoItemRow(item)
          }
        }
      }

      if let input = content.inputDisplay, !input.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Input")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          Text(input)
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
        }
      }

      if let output = content.outputDisplay, !output.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Output")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          Text(output)
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
        }
      }
    }
  }

  private func todoItemRow(_ item: ServerToolTodoItem) -> some View {
    let isCompleted = item.status == "completed"
    let isInProgress = item.status == "in_progress"

    return HStack(spacing: Spacing.sm) {
      Image(systemName: isCompleted
        ? "checkmark.circle.fill"
        : isInProgress ? "circle.dotted" : "circle")
        .font(.system(size: IconScale.md))
        .foregroundStyle(
          isCompleted ? Color.feedbackPositive
            : isInProgress ? Color.accent
            : Color.textQuaternary
        )

      Text(item.content ?? item.status)
        .font(.system(size: TypeScale.body))
        .foregroundStyle(isCompleted ? Color.textTertiary : Color.textSecondary)
    }
  }
}
