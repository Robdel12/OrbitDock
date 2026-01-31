//
//  ReadCard.swift
//  CommandCenter
//
//  Compact, expandable file preview card
//

import SwiftUI

struct ReadCard: View {
    let message: TranscriptMessage
    @Binding var isExpanded: Bool

    private var color: Color { ToolCardStyle.color(for: message.toolName) }
    private var language: String { ToolCardStyle.detectLanguage(from: message.filePath) }

    private var output: String { message.toolOutput ?? "" }
    private var lines: [String] { output.components(separatedBy: "\n") }
    private var lineCount: Int { lines.count }
    private var hasContent: Bool { !output.isEmpty && !message.isInProgress }

    var body: some View {
        ToolCardContainer(color: color, isExpanded: $isExpanded, hasContent: hasContent) {
            header
        } content: {
            expandedContent
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)

            if let path = message.filePath {
                let filename = path.components(separatedBy: "/").last ?? path

                Text(filename)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(ToolCardStyle.shortenPath(path))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text("Read")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
            }

            Spacer()

            if !message.isInProgress {
                HStack(spacing: 8) {
                    ToolCardStatsBadge("\(lineCount) lines")

                    if !language.isEmpty {
                        ToolCardStatsBadge(language.capitalized, color: color)
                    }

                    ToolCardDuration(duration: message.formattedDuration)
                }
            }

            if message.isInProgress {
                ProgressView()
                    .controlSize(.mini)
            } else if hasContent {
                ToolCardExpandButton(isExpanded: $isExpanded)
            }
        }
    }

    // MARK: - Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        let maxLines = 50
        let previewLines = Array(lines.prefix(maxLines))
        let hasMore = lineCount > maxLines

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(previewLines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 0) {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.25))
                        .frame(width: 36, alignment: .trailing)
                        .padding(.trailing, 8)

                    Text(SyntaxHighlighter.highlightLine(line.isEmpty ? " " : line, language: language.isEmpty ? nil : language))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 1)
            }

            if hasMore {
                Text("... +\(lineCount - maxLines) more lines")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}
