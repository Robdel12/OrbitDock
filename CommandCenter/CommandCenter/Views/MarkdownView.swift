//
//  MarkdownView.swift
//  CommandCenter
//
//  Rich markdown rendering for Claude messages

import SwiftUI

struct MarkdownView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                case .text(let text):
                    MarkdownTextView(text: text)
                }
            }
        }
    }

    // MARK: - Block Parsing

    private enum ContentBlock {
        case text(String)
        case code(language: String?, code: String)
    }

    private func parseBlocks() -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        let remaining = content

        // Pattern for fenced code blocks: ```language\ncode\n```
        let codeBlockPattern = #"```(\w*)\n?([\s\S]*?)```"#

        guard let regex = try? NSRegularExpression(pattern: codeBlockPattern) else {
            return [.text(content)]
        }

        var lastEnd = 0
        let nsString = remaining as NSString
        let matches = regex.matches(in: remaining, range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            // Text before this code block
            let textRange = NSRange(location: lastEnd, length: match.range.location - lastEnd)
            let textBefore = nsString.substring(with: textRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if !textBefore.isEmpty {
                blocks.append(.text(textBefore))
            }

            // Extract language and code
            let languageRange = match.range(at: 1)
            let codeRange = match.range(at: 2)

            let language = languageRange.location != NSNotFound
                ? nsString.substring(with: languageRange)
                : nil
            let code = codeRange.location != NSNotFound
                ? nsString.substring(with: codeRange).trimmingCharacters(in: .newlines)
                : ""

            if !code.isEmpty {
                blocks.append(.code(language: language?.isEmpty == true ? nil : language, code: code))
            }

            lastEnd = match.range.location + match.range.length
        }

        // Remaining text after last code block
        if lastEnd < nsString.length {
            let remainingText = nsString.substring(from: lastEnd).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainingText.isEmpty {
                blocks.append(.text(remainingText))
            }
        }

        // If no blocks found, treat entire content as text
        if blocks.isEmpty {
            blocks.append(.text(content))
        }

        return blocks
    }
}

// MARK: - Code Block View

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with language badge and copy button
            if language != nil || isHovering {
                HStack {
                    if let lang = language, !lang.isEmpty {
                        Text(lang)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.backgroundPrimary, in: RoundedRectangle(cornerRadius: 3))
                    }

                    Spacer()

                    if isHovering {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color.backgroundPrimary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onHover { isHovering = $0 }
    }
}

// MARK: - Markdown Text View (for non-code content)

struct MarkdownTextView: View {
    let text: String

    var body: some View {
        Text(attributedText)
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .lineSpacing(3)
    }

    private var attributedText: AttributedString {
        // Try native markdown parsing first
        if let attributed = try? AttributedString(markdown: text, options: .init(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )) {
            return styleAttributedString(attributed)
        }

        // Fallback to plain text
        return AttributedString(text)
    }

    private func styleAttributedString(_ input: AttributedString) -> AttributedString {
        var result = input

        // Style inline code with background
        for run in result.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                let range = run.range
                result[range].font = .system(size: 11, design: .monospaced)
                result[range].backgroundColor = Color.backgroundPrimary
            }
        }

        return result
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            MarkdownView(content: """
            Here's a **bold statement** and some *italic text*.

            Check out this `inline code` example.

            ```swift
            func hello() {
                print("Hello, World!")
            }
            ```

            And here's a list:
            - Item one
            - Item two
            - Item three

            More text after the code block with [a link](https://example.com).
            """)
        }
        .padding()
    }
    .frame(width: 500, height: 400)
    .background(Color.backgroundSecondary)
}
