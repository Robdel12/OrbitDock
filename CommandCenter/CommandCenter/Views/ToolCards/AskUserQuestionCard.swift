//
//  AskUserQuestionCard.swift
//  OrbitDock
//
//  Shows questions posed to the user with options
//

import SwiftUI

struct AskUserQuestionCard: View {
    let message: TranscriptMessage
    @Binding var isExpanded: Bool

    private var color: Color { Color(red: 0.95, green: 0.65, blue: 0.25) }  // Amber

    private var questions: [[String: Any]] {
        (message.toolInput?["questions"] as? [[String: Any]]) ?? []
    }

    private var output: String { message.toolOutput ?? "" }

    var body: some View {
        ToolCardContainer(color: color, isExpanded: $isExpanded, hasContent: !questions.isEmpty) {
            header
        } content: {
            expandedContent
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Question")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(color)

                    if questions.count > 1 {
                        Text("\(questions.count) questions")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                // Show first question as subtitle
                if let firstQuestion = questions.first,
                   let text = firstQuestion["question"] as? String {
                    Text(text.count > 80 ? String(text.prefix(80)) + "..." : text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if !message.isInProgress {
                // Show if answered
                if !output.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.5))
                        Text("Answered")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                ToolCardDuration(duration: message.formattedDuration)
            }

            if message.isInProgress {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Waiting...")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(color)
                }
            } else if !questions.isEmpty {
                ToolCardExpandButton(isExpanded: $isExpanded)
            }
        }
    }

    // MARK: - Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                questionView(question, index: index)

                if index < questions.count - 1 {
                    Divider()
                        .padding(.horizontal, 12)
                }
            }

            // User's response
            if !output.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RESPONSE")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.quaternary)
                        .tracking(0.5)

                    Text(output)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(color)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color.opacity(0.1))
            }
        }
    }

    @ViewBuilder
    private func questionView(_ question: [String: Any], index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Question header
            if let header = question["header"] as? String {
                Text(header.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(color.opacity(0.8))
                    .tracking(0.5)
            }

            // Question text
            if let text = question["question"] as? String {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            }

            // Options
            if let options = question["options"] as? [[String: Any]] {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        optionView(option)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func optionView(_ option: [String: Any]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color.opacity(0.3))
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                if let label = option["label"] as? String {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.9))
                }

                if let desc = option["description"] as? String, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
