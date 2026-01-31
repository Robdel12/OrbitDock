//
//  GlobCard.swift
//  CommandCenter
//
//  File tree view for glob results
//

import SwiftUI

struct GlobCard: View {
    let message: TranscriptMessage
    @Binding var isExpanded: Bool

    private var color: Color { ToolCardStyle.color(for: message.toolName) }

    private var output: String { message.toolOutput ?? "" }
    private var files: [String] { output.components(separatedBy: "\n").filter { !$0.isEmpty } }
    private var fileCount: Int { files.count }
    private var pattern: String { message.globPattern ?? "**/*" }

    // Group files by directory
    private var grouped: [String: [String]] {
        Dictionary(grouping: files) { path -> String in
            let components = path.components(separatedBy: "/")
            if components.count > 1 {
                return components.dropLast().joined(separator: "/")
            }
            return "."
        }
    }

    private var sortedDirs: [String] { grouped.keys.sorted() }

    var body: some View {
        ToolCardContainer(color: color, isExpanded: $isExpanded, hasContent: !files.isEmpty) {
            header
        } content: {
            expandedContent
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 2) {
                Text("Glob")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)

                Text(pattern)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !message.isInProgress {
                HStack(spacing: 12) {
                    Text("\(fileCount) \(fileCount == 1 ? "file" : "files")")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(color)

                    ToolCardDuration(duration: message.formattedDuration)
                }
            }

            if message.isInProgress {
                ProgressView()
                    .controlSize(.mini)
            } else if fileCount > 0 {
                ToolCardExpandButton(isExpanded: $isExpanded)
            }
        }
    }

    // MARK: - Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        let maxDirs = isExpanded ? sortedDirs.count : min(5, sortedDirs.count)
        let displayDirs = Array(sortedDirs.prefix(maxDirs))
        let hasMoreDirs = sortedDirs.count > maxDirs

        VStack(alignment: .leading, spacing: 0) {
            ForEach(displayDirs, id: \.self) { dir in
                let dirFiles = grouped[dir] ?? []

                VStack(alignment: .leading, spacing: 0) {
                    // Directory header
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        Text(dir == "." ? "(root)" : dir)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.8))
                        Text("(\(dirFiles.count))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 12)

                    // Files
                    ForEach(dirFiles.prefix(10), id: \.self) { file in
                        let filename = file.components(separatedBy: "/").last ?? file
                        HStack(spacing: 6) {
                            Image(systemName: "doc")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Text(filename)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .padding(.leading, 28)
                        .padding(.trailing, 12)
                    }

                    if dirFiles.count > 10 {
                        Text("... +\(dirFiles.count - 10) more")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 28)
                            .padding(.vertical, 2)
                    }
                }
            }

            if hasMoreDirs {
                Text("... +\(sortedDirs.count - maxDirs) more directories")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .padding(.vertical, 6)
    }
}
