//
//  DiffFileView.swift
//  OrbitDock
//
//  Renders all hunks for a single FileDiff with file header bar,
//  hunk navigation, and collapsible context regions.
//

import SwiftUI

struct DiffFileView: View {
  let fileDiff: FileDiff
  let projectPath: String
  @Binding var focusedHunkIndex: Int

  @AppStorage("preferredEditor") private var preferredEditor: String = ""

  // Track which context collapse bars are expanded
  @State private var expandedContextBars: Set<Int> = []
  @State private var isHeaderHovered = false

  private var language: String {
    ToolCardStyle.detectLanguage(from: fileDiff.newPath)
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView([.vertical, .horizontal], showsIndicators: true) {
        VStack(alignment: .leading, spacing: 0) {
          fileHeader

          ForEach(Array(fileDiff.hunks.enumerated()), id: \.element.id) { index, hunk in
            // Context collapse bar between hunks
            if index > 0 {
              let gap = gapBetweenHunks(prev: fileDiff.hunks[index - 1], current: hunk)
              if gap > 0 {
                ContextCollapseBar(
                  hiddenLineCount: gap,
                  isExpanded: Binding(
                    get: { expandedContextBars.contains(index) },
                    set: { val in
                      if val { expandedContextBars.insert(index) }
                      else { expandedContextBars.remove(index) }
                    }
                  )
                )
              }
            }

            DiffHunkView(
              hunk: hunk,
              language: language,
              hunkIndex: index
            ) { _, _ in }
          }

          // Bottom spacing
          Color.clear.frame(height: 32)
        }
      }
      .onChange(of: focusedHunkIndex) { _, newIndex in
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
          proxy.scrollTo("hunk-\(newIndex)", anchor: .top)
        }
      }
    }
  }

  // MARK: - File Header

  private var fileHeader: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        // File change type icon
        ZStack {
          Circle()
            .fill(changeTypeColor.opacity(0.15))
            .frame(width: 22, height: 22)
          Image(systemName: fileIcon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(changeTypeColor)
        }
        .padding(.trailing, 8)

        // File path with hierarchy
        filePathView
          .padding(.trailing, 8)

        // Stats badge
        HStack(spacing: 6) {
          if fileDiff.stats.additions > 0 {
            HStack(spacing: 2) {
              Text("+")
                .foregroundStyle(Color(red: 0.4, green: 0.95, blue: 0.5).opacity(0.7))
              Text("\(fileDiff.stats.additions)")
                .foregroundStyle(Color(red: 0.4, green: 0.95, blue: 0.5))
            }
          }
          if fileDiff.stats.deletions > 0 {
            HStack(spacing: 2) {
              Text("\u{2212}")
                .foregroundStyle(Color(red: 1.0, green: 0.5, blue: 0.5).opacity(0.7))
              Text("\(fileDiff.stats.deletions)")
                .foregroundStyle(Color(red: 1.0, green: 0.5, blue: 0.5))
            }
          }
        }
        .font(.system(size: 10, weight: .bold, design: .monospaced))

        Spacer()

        // Hunk navigator
        if fileDiff.hunks.count > 1 {
          HStack(spacing: 2) {
            Text("\(focusedHunkIndex + 1)/\(fileDiff.hunks.count)")
              .font(.system(size: 9, weight: .medium, design: .monospaced))
              .foregroundStyle(.tertiary)
              .padding(.trailing, 4)

            Button {
              focusedHunkIndex = max(0, focusedHunkIndex - 1)
            } label: {
              Image(systemName: "chevron.up")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(focusedHunkIndex <= 0)

            Button {
              focusedHunkIndex = min(fileDiff.hunks.count - 1, focusedHunkIndex + 1)
            } label: {
              Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(focusedHunkIndex >= fileDiff.hunks.count - 1)
          }
          .padding(.trailing, 8)
        }

        // Open in editor button
        Button {
          openFileInEditor(line: fileDiff.hunks.first?.newStart)
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "arrow.up.forward.square")
              .font(.system(size: 10, weight: .medium))
            Text("Open")
              .font(.system(size: 10, weight: .medium))
          }
          .foregroundStyle(isHeaderHovered ? .primary : .secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(
            Color.surfaceHover.opacity(isHeaderHovered ? 1 : 0.5),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
          )
        }
        .buttonStyle(.plain)
        .help("Open in editor (\u{2318}O)")
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .onHover { hovering in
        isHeaderHovered = hovering
      }

      // Bottom accent line
      Rectangle()
        .fill(
          LinearGradient(
            colors: [changeTypeColor.opacity(0.4), changeTypeColor.opacity(0.05)],
            startPoint: .leading,
            endPoint: .trailing
          )
        )
        .frame(height: 1)
    }
    .background(Color.backgroundSecondary)
  }

  private var filePathView: some View {
    let path = fileDiff.newPath
    let components = path.components(separatedBy: "/")
    let fileName = components.last ?? path
    let dirPath = components.count > 1 ? components.dropLast().joined(separator: "/") + "/" : ""

    return HStack(spacing: 0) {
      if !dirPath.isEmpty {
        Text(dirPath)
          .font(.system(size: 12, weight: .regular, design: .monospaced))
          .foregroundStyle(.tertiary)
      }
      Text(fileName)
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .foregroundStyle(.primary)
    }
    .lineLimit(1)
  }

  // MARK: - Helpers

  private var fileIcon: String {
    switch fileDiff.changeType {
      case .added: "plus"
      case .deleted: "minus"
      case .renamed: "arrow.right"
      case .modified: "pencil"
    }
  }

  private var changeTypeColor: Color {
    switch fileDiff.changeType {
      case .added: Color(red: 0.4, green: 0.95, blue: 0.5)
      case .deleted: Color(red: 1.0, green: 0.5, blue: 0.5)
      case .renamed: Color.accent
      case .modified: Color.accent
    }
  }

  private func gapBetweenHunks(prev: DiffHunk, current: DiffHunk) -> Int {
    let prevEnd = prev.oldStart + prev.oldCount
    let currentStart = current.oldStart
    return max(0, currentStart - prevEnd)
  }

  // MARK: - Open in Editor

  func openFileInEditor(line: Int?) {
    let fullPath = projectPath.hasSuffix("/")
      ? projectPath + fileDiff.newPath
      : projectPath + "/" + fileDiff.newPath

    guard !preferredEditor.isEmpty else {
      _ = Platform.services.openURL(URL(fileURLWithPath: fullPath))
      return
    }

    #if !os(macOS)
      _ = Platform.services.openURL(URL(fileURLWithPath: fullPath))
      return
    #else
      let lineArg = line ?? 1

      let appNames: [String: String] = [
        "code": "Visual Studio Code",
        "cursor": "Cursor",
        "zed": "Zed",
        "subl": "Sublime Text",
      ]

      switch preferredEditor {
        case "code", "cursor":
        if let appName = appNames[preferredEditor] {
          let process = Process()
          process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
          process.arguments = ["-a", appName, "--args", "--goto", "\(fullPath):\(lineArg)"]
          try? process.run()
        }

        case "zed":
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Zed", "--args", "\(fullPath):\(lineArg)"]
        try? process.run()

        case "subl":
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Sublime Text", "--args", "\(fullPath):\(lineArg)"]
        try? process.run()

        case "emacs":
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["emacsclient", "+\(lineArg)", fullPath]
        try? process.run()

        case "vim", "nvim":
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [preferredEditor, "+\(lineArg)", fullPath]
        try? process.run()

        default:
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [preferredEditor, fullPath]
        try? process.run()
      }
    #endif
  }
}
