//
//  AskUserQuestionCard.swift
//  OrbitDock
//
//  Structured rendering for AskUserQuestion tool payloads.
//

import SwiftUI

struct AskUserQuestionCard: View {
  let message: TranscriptMessage
  @Binding var isExpanded: Bool

  private let color = Color.toolQuestion

  private struct ParsedOption: Hashable {
    let label: String
    let description: String?
  }

  private struct ParsedQuestion: Hashable {
    let id: String
    let header: String?
    let question: String
    let options: [ParsedOption]
    let allowsMultipleSelection: Bool
    let allowsOther: Bool
    let isSecret: Bool
  }

  private var questions: [ParsedQuestion] {
    guard let rawQuestions = message.toolInput?["questions"] as? [[String: Any]] else {
      return []
    }

    return rawQuestions.enumerated().compactMap { index, raw in
      let id = (raw["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      let fallbackId = String(index)
      let normalizedId = (id?.isEmpty == false) ? id! : fallbackId

      let questionText = (raw["question"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !questionText.isEmpty else { return nil }

      let header = (raw["header"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let normalizedHeader: String? = {
        guard let header, !header.isEmpty else { return nil }
        return header
      }()

      let options: [ParsedOption] = (raw["options"] as? [[String: Any]] ?? []).compactMap { option in
        let label = (option["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !label.isEmpty else { return nil }
        let description = (option["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedOption(label: label, description: description?.isEmpty == true ? nil : description)
      }

      return ParsedQuestion(
        id: normalizedId,
        header: normalizedHeader,
        question: questionText,
        options: options,
        allowsMultipleSelection: raw["allows_multiple_selection"] as? Bool ?? false,
        allowsOther: raw["allows_other"] as? Bool ?? true,
        isSecret: raw["is_secret"] as? Bool ?? false
      )
    }
  }

  private var output: String {
    (message.toolOutput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var firstQuestionPreview: String? {
    guard let first = questions.first else { return nil }
    return first.question
  }

  var body: some View {
    ToolCardContainer(color: color, isExpanded: $isExpanded, hasContent: !questions.isEmpty) {
      header
    } content: {
      expandedContent
    }
  }

  private var header: some View {
    HStack(spacing: Spacing.md) {
      Image(systemName: "questionmark.circle.fill")
        .font(.system(size: TypeScale.subhead, weight: .medium))
        .foregroundStyle(color)

      VStack(alignment: .leading, spacing: Spacing.gap) {
        HStack(spacing: Spacing.sm) {
          Text("Question")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(color)

          if questions.count > 1 {
            Text("\(questions.count) prompts")
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(.secondary)
          }
        }

        if let preview = firstQuestionPreview {
          Text(preview.count > 88 ? String(preview.prefix(88)) + "..." : preview)
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Spacer()

      if !output.isEmpty {
        Label("Answered", systemImage: "checkmark.circle.fill")
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(Color.feedbackPositive)
      }

      if message.isInProgress {
        HStack(spacing: Spacing.sm_) {
          ProgressView()
            .controlSize(.mini)
          Text("Waiting...")
            .font(.system(size: TypeScale.meta, weight: .medium))
            .foregroundStyle(color)
        }
      } else {
        ToolCardDuration(duration: message.formattedDuration)
        if !questions.isEmpty {
          ToolCardExpandButton(isExpanded: $isExpanded)
        }
      }
    }
  }

  private var expandedContent: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
        questionSection(question, index: index)
      }

      if !output.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.sm_) {
          Text("Submitted Answer")
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(Color.textSecondary)

          Text(output)
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.textPrimary)
            .textSelection(.enabled)
        }
        .padding(Spacing.md_)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: CGFloat(Radius.md), style: .continuous))
      }
    }
    .padding(Spacing.md)
  }

  private func questionSection(_ question: ParsedQuestion, index: Int) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        Text("\(index + 1).")
          .font(.system(size: TypeScale.meta, weight: .semibold, design: .monospaced))
          .foregroundStyle(color)

        VStack(alignment: .leading, spacing: Spacing.sm_) {
          if let header = question.header {
            Text(header.uppercased())
              .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
              .foregroundStyle(Color.textSecondary)
              .tracking(0.5)
          }

          Text(question.question)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 0)
      }

      if !question.options.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.sm_) {
          ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
            let optionTag = optionIndex < 26
              ? String(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")[optionIndex])
              : "•"
            HStack(alignment: .top, spacing: Spacing.sm) {
              Text(optionTag)
                .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 14)

              VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(option.label)
                  .font(.system(size: TypeScale.meta, weight: .medium))
                  .foregroundStyle(Color.textPrimary)

                if let description = option.description {
                  Text(description)
                    .font(.system(size: TypeScale.micro))
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
              }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.sm_)
            .background(
              Color.backgroundPrimary.opacity(0.75),
              in: RoundedRectangle(cornerRadius: CGFloat(Radius.sm), style: .continuous)
            )
          }
        }
      }

      HStack(spacing: Spacing.sm_) {
        if question.allowsMultipleSelection {
          chip("Multi-select")
        }
        if question.allowsOther {
          chip("Custom answer")
        }
        if question.isSecret {
          chip("Secret")
        }
      }
    }
    .padding(Spacing.md_)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color.backgroundTertiary.opacity(0.5),
      in: RoundedRectangle(cornerRadius: CGFloat(Radius.md), style: .continuous)
    )
  }

  private func chip(_ label: String) -> some View {
    Text(label)
      .font(.system(size: TypeScale.mini, weight: .semibold))
      .foregroundStyle(Color.textSecondary)
      .padding(.horizontal, 7)
      .padding(.vertical, Spacing.xs)
      .background(Color.backgroundPrimary, in: Capsule())
  }
}
