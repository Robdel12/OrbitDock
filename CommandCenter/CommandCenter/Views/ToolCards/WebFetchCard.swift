//
//  WebFetchCard.swift
//  OrbitDock
//
//  URL fetch with preview of content
//

import SwiftUI

struct WebFetchCard: View {
    let message: TranscriptMessage
    @Binding var isExpanded: Bool

    private var color: Color { Color(red: 0.3, green: 0.75, blue: 0.75) }  // Teal

    private var url: String {
        (message.toolInput?["url"] as? String) ?? ""
    }

    private var prompt: String {
        (message.toolInput?["prompt"] as? String) ?? ""
    }

    private var domain: String {
        guard let urlObj = URL(string: url) else { return url }
        return urlObj.host ?? url
    }

    private var output: String { message.toolOutput ?? "" }

    // Detect status from output
    private var status: FetchStatus {
        if message.isInProgress { return .loading }
        if output.contains("error") || output.contains("Error") || output.contains("failed") {
            return .error
        }
        if output.contains("redirect") {
            return .redirect
        }
        return .success
    }

    private enum FetchStatus {
        case loading, success, error, redirect

        var icon: String {
            switch self {
            case .loading: return "arrow.down.circle"
            case .success: return "checkmark.circle.fill"
            case .error: return "xmark.circle.fill"
            case .redirect: return "arrow.turn.up.right"
            }
        }

        var color: Color {
            switch self {
            case .loading: return .secondary
            case .success: return Color(red: 0.4, green: 0.9, blue: 0.5)
            case .error: return Color(red: 1.0, green: 0.45, blue: 0.45)
            case .redirect: return Color(red: 0.95, green: 0.7, blue: 0.3)
            }
        }
    }

    var body: some View {
        ToolCardContainer(color: color, isExpanded: $isExpanded) {
            header
        } content: {
            expandedContent
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("WebFetch")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(color)

                    // Status indicator
                    Image(systemName: status.icon)
                        .font(.system(size: 12))
                        .foregroundStyle(status.color)
                }

                Text(domain)
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
                    Text("Fetching...")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(color)
                }
            } else {
                ToolCardExpandButton(isExpanded: $isExpanded)
            }
        }
    }

    // MARK: - Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // URL
            VStack(alignment: .leading, spacing: 6) {
                Text("URL")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.quaternary)
                    .tracking(0.5)

                HStack {
                    Text(url)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.9))
                        .textSelection(.enabled)
                        .lineLimit(2)

                    Spacer()

                    Button {
                        if let urlObj = URL(string: url) {
                            NSWorkspace.shared.open(urlObj)
                        }
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Open in browser")
                }
            }
            .padding(12)

            // Prompt
            if !prompt.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PROMPT")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.quaternary)
                        .tracking(0.5)

                    Text(prompt.count > 200 ? String(prompt.prefix(200)) + "..." : prompt)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.8))
                        .textSelection(.enabled)
                }
                .padding(12)
                .background(Color.backgroundTertiary.opacity(0.3))
            }

            // Output/Response
            if !output.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RESPONSE")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.quaternary)
                        .tracking(0.5)

                    ScrollView {
                        Text(output.count > 1500 ? String(output.prefix(1500)) + "\n[...]" : output)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.8))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
                .padding(12)
                .background(Color.backgroundTertiary.opacity(0.5))
            }
        }
    }
}
