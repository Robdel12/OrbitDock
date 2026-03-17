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
        let inProgress = display.todoItems.filter { $0.status == "in_progress" }.count
        let total = display.todoItems.count

        // Operation header
        Text(detectOperation(completed: completed, inProgress: inProgress, total: total))
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.toolTodo)
          .padding(.bottom, Spacing.xs)

        // Progress bar
        ProgressSummaryBar(completed: completed, total: total)

        // Todo items — sorted: in-progress first, then pending, then completed
        let sortedItems = display.todoItems.sorted { a, b in
          let order: (String) -> Int = { status in
            switch status {
              case "in_progress": 0
              case "pending": 1
              case "completed": 2
              default: 1
            }
          }
          return order(a.status) < order(b.status)
        }

        VStack(alignment: .leading, spacing: Spacing.sm) {
          ForEach(Array(sortedItems.enumerated()), id: \.offset) { _, item in
            todoItemRow(item)
          }
        }
      }

      // Minimal fallback when todoItems is empty but content exists
      if display == nil || display?.todoItems.isEmpty == true {
        if let input = content.inputDisplay, !input.isEmpty {
          Text(input)
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
        }

        if let output = content.outputDisplay, !output.isEmpty {
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

  private func detectOperation(completed: Int, inProgress: Int, total: Int) -> String {
    if completed == total { return "All \(total) items complete" }
    if inProgress > 0 { return "\(inProgress) in progress, \(completed)/\(total) done" }
    return "\(total) items"
  }

  private func todoItemRow(_ item: ServerToolTodoItem) -> some View {
    let isCompleted = item.status == "completed"
    let isInProgress = item.status == "in_progress"

    return VStack(alignment: .leading, spacing: Spacing.xxs) {
      HStack(spacing: Spacing.sm) {
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
          .foregroundStyle(isCompleted ? Color.textQuaternary : Color.textSecondary)
          .strikethrough(isCompleted, color: Color.textQuaternary)
      }

      // Show activeForm as secondary line for in-progress items
      if isInProgress, let activeForm = item.activeForm, !activeForm.isEmpty {
        Text(activeForm)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
          .padding(.leading, IconScale.md + Spacing.sm)
      }
    }
  }
}
