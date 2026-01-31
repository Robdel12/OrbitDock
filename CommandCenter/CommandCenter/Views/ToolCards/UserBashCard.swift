//
//  UserBashCard.swift
//  CommandCenter
//
//  Displays user-initiated bash commands (captured via <bash-input> tags)
//

import SwiftUI

// MARK: - Parsed Bash Content

struct ParsedBashContent {
    let input: String
    let stdout: String
    let stderr: String

    var hasOutput: Bool { !stdout.isEmpty || !stderr.isEmpty }
    var hasError: Bool { !stderr.isEmpty }
    var hasInput: Bool { !input.isEmpty }

    /// Parse content containing <bash-input>, <bash-stdout>, <bash-stderr> tags
    /// Handles cases where only some tags are present
    static func parse(from content: String) -> ParsedBashContent? {
        // Must contain at least one bash tag
        let hasBashInput = content.contains("<bash-input>")
        let hasBashStdout = content.contains("<bash-stdout>")
        let hasBashStderr = content.contains("<bash-stderr>")

        guard hasBashInput || hasBashStdout || hasBashStderr else { return nil }

        let input = extractTag("bash-input", from: content)
        let stdout = extractTag("bash-stdout", from: content)
        let stderr = extractTag("bash-stderr", from: content)

        // Must have at least some content
        guard !input.isEmpty || !stdout.isEmpty || !stderr.isEmpty else { return nil }

        return ParsedBashContent(input: input, stdout: stdout, stderr: stderr)
    }

    private static func extractTag(_ tag: String, from content: String) -> String {
        let openTag = "<\(tag)>"
        let closeTag = "</\(tag)>"

        guard let startRange = content.range(of: openTag),
              let endRange = content.range(of: closeTag, range: startRange.upperBound..<content.endIndex) else {
            return ""
        }

        return String(content[startRange.upperBound..<endRange.lowerBound])
    }
}

// MARK: - User Bash Card View

struct UserBashCard: View {
    let bash: ParsedBashContent
    let timestamp: Date

    @State private var isExpanded = false
    @State private var isHovering = false

    private let terminalColor = Color(red: 0.35, green: 0.75, blue: 0.45)  // Vibrant terminal green

    /// Only show error state if stderr has actual content
    private var showErrorState: Bool {
        !bash.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            // Meta line - right aligned
            HStack(spacing: 8) {
                Text(formatTime(timestamp))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.quaternary)

                Text("You")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }

            // Bash card - right aligned
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 10) {
                    // Terminal icon
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(terminalColor)
                        .frame(width: 16)

                    if bash.hasInput {
                        // Command with prompt
                        Text("$")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(terminalColor.opacity(0.8))

                        Text(bash.input)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.9))
                            .lineLimit(isExpanded ? nil : 1)
                    } else {
                        // No input - show label
                        Text("Terminal output")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Status indicators
                    HStack(spacing: 6) {
                        if showErrorState {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        }

                        if bash.hasOutput {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(terminalColor.opacity(isHovering ? 0.12 : 0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(terminalColor.opacity(0.15), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if bash.hasOutput {
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
                            isExpanded.toggle()
                        }
                    }
                }
                .onHover { isHovering = $0 }

                // Output panel
                if isExpanded && bash.hasOutput {
                    VStack(alignment: .leading, spacing: 0) {
                        if !bash.stdout.isEmpty {
                            outputSection(text: bash.stdout, isError: false)
                        }

                        if showErrorState {
                            outputSection(text: bash.stderr, isError: true)
                                .padding(.top, bash.stdout.isEmpty ? 0 : 8)
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.backgroundTertiary)
                    )
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .onAppear {
            // Auto-expand if there's no input command
            if !bash.hasInput && bash.hasOutput {
                isExpanded = true
            }
        }
    }

    @ViewBuilder
    private func outputSection(text: String, isError: Bool) -> some View {
        let displayText = text.count > 3000 ? String(text.prefix(3000)) + "\n..." : text

        VStack(alignment: .leading, spacing: 4) {
            if isError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                    Text("stderr")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.orange.opacity(0.8))
            }

            ScrollView {
                Text(displayText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isError ? .orange.opacity(0.85) : .primary.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private func formatTime(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }
}

// MARK: - Preview

#Preview {
    VStack(alignment: .trailing, spacing: 20) {
        // With command
        UserBashCard(
            bash: ParsedBashContent(
                input: "git status",
                stdout: "On branch main\nnothing to commit, working tree clean",
                stderr: ""
            ),
            timestamp: Date()
        )

        // Output only (no command)
        UserBashCard(
            bash: ParsedBashContent(
                input: "",
                stdout: "On branch main\nChanges not staged for commit:\n  modified: file.swift",
                stderr: ""
            ),
            timestamp: Date()
        )

        // With error
        UserBashCard(
            bash: ParsedBashContent(
                input: "git push",
                stdout: "",
                stderr: "fatal: not a git repository"
            ),
            timestamp: Date()
        )
    }
    .padding(32)
    .frame(width: 600)
    .background(Color.backgroundPrimary)
}
