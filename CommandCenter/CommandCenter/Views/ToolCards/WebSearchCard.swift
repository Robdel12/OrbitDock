//
//  WebSearchCard.swift
//  OrbitDock
//
//  Web search with query and results
//

import SwiftUI

struct WebSearchCard: View {
    let message: TranscriptMessage
    @Binding var isExpanded: Bool

    private var color: Color { Color(red: 0.3, green: 0.75, blue: 0.75) }  // Teal

    private var query: String {
        (message.toolInput?["query"] as? String) ?? ""
    }

    private var output: String { message.toolOutput ?? "" }

    // Try to count results from output
    private var resultCount: Int? {
        // Look for common patterns in search results
        let lines = output.components(separatedBy: "\n")
        let resultLines = lines.filter {
            $0.contains("http") || $0.contains("https") || $0.contains("- [")
        }
        return resultLines.isEmpty ? nil : resultLines.count
    }

    var body: some View {
        ToolCardContainer(color: color, isExpanded: $isExpanded, hasContent: !output.isEmpty) {
            header
        } content: {
            expandedContent
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("WebSearch")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(color)

                    if let count = resultCount {
                        Text("\(count) results")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(query)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !message.isInProgress {
                ToolCardDuration(duration: message.formattedDuration)
            }

            if message.isInProgress {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Searching...")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(color)
                }
            } else if !output.isEmpty {
                ToolCardExpandButton(isExpanded: $isExpanded)
            }
        }
    }

    // MARK: - Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Query
            VStack(alignment: .leading, spacing: 6) {
                Text("QUERY")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.quaternary)
                    .tracking(0.5)

                Text(query)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            .padding(12)

            // Results
            if !output.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RESULTS")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.quaternary)
                        .tracking(0.5)

                    ScrollView {
                        Text(output.count > 2000 ? String(output.prefix(2000)) + "\n[...]" : output)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.8))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 250)
                }
                .padding(12)
                .background(Color.backgroundTertiary.opacity(0.5))
            }
        }
    }
}
