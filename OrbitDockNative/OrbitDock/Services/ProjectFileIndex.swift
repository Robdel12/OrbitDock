import Foundation

@MainActor
@Observable
final class ProjectFileIndex {
  struct ProjectFile: Identifiable, Hashable, Sendable {
    let id: String // relative path (unique within project)
    let name: String // filename (e.g. "main.rs")
    let relativePath: String // from project root (e.g. "src/main.rs")
  }

  private var cache: [String: [ProjectFile]] = [:]
  private var loading: Set<String> = []

  func files(for projectPath: String) -> [ProjectFile] {
    cache[projectPath] ?? []
  }

  /// Returns true if files are already cached or loading for this path.
  func isReady(for projectPath: String) -> Bool {
    cache[projectPath] != nil || loading.contains(projectPath)
  }

  func loadIfNeeded(_ projectPath: String) async {
    guard cache[projectPath] == nil, !loading.contains(projectPath) else { return }
    loading.insert(projectPath)
    defer { loading.remove(projectPath) }

    // Prefer git-aware indexing so large repos do not drown file mentions in
    // vendor, build, or ignored content. Fall back to a bounded filesystem
    // scan for non-git directories.
    cache[projectPath] = await Self.scanProjectFiles(in: projectPath)
  }

  func search(_ query: String, in projectPath: String) -> [ProjectFile] {
    let all = files(for: projectPath)
    guard !query.isEmpty else { return all }

    let q = query.lowercased()

    // Partition: name matches first, then path-only matches
    var nameMatches: [ProjectFile] = []
    var pathMatches: [ProjectFile] = []

    for file in all {
      if file.name.lowercased().contains(q) {
        nameMatches.append(file)
      } else if file.relativePath.lowercased().contains(q) {
        pathMatches.append(file)
      }
    }

    return nameMatches + pathMatches
  }

  nonisolated static func projectFiles(fromRelativePaths relativePaths: [String]) -> [ProjectFile] {
    let normalized = Set(relativePaths.compactMap { rawPath -> String? in
      let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      return trimmed.replacingOccurrences(of: "\\", with: "/")
    })

    return normalized
      .map { relativePath in
        ProjectFile(
          id: relativePath,
          name: URL(fileURLWithPath: relativePath).lastPathComponent,
          relativePath: relativePath
        )
      }
      .sorted { $0.relativePath < $1.relativePath }
  }

  nonisolated static func gitRelativePaths(in directory: String) -> [String]? {
    #if os(macOS)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", directory, "ls-files", "--cached", "--others", "--exclude-standard"]

    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()

    do {
      try process.run()
    } catch {
      return nil
    }

    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }

    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return nil }
    return output.split(separator: "\n").map(String.init)
    #else
    return nil
    #endif
  }

  private nonisolated static func scanProjectFiles(in directory: String) async -> [ProjectFile] {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        if let gitRelativePaths = Self.gitRelativePaths(in: directory), !gitRelativePaths.isEmpty {
          continuation.resume(returning: Self.projectFiles(fromRelativePaths: gitRelativePaths))
          return
        }

        continuation.resume(returning: Self.scanWithFileManagerSync(in: directory))
      }
    }
  }

  private nonisolated static func scanWithFileManagerSync(in directory: String) -> [ProjectFile] {
    let rootURL = URL(fileURLWithPath: directory, isDirectory: true)
    let fm = FileManager.default

    guard let enumerator = fm.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants],
      errorHandler: nil
    ) else {
      return []
    }

    let excludedDirectoryNames: Set<String> = [
      ".git", ".build", "node_modules", "Pods", "DerivedData", "build", "dist", "vendor",
      "Vendors"
    ]
    let maxFiles = 20_000
    var relativePaths: [String] = []
    relativePaths.reserveCapacity(2_500)

    for case let fileURL as URL in enumerator {
      if relativePaths.count >= maxFiles {
        break
      }

      let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
      if resourceValues?.isDirectory == true {
        if excludedDirectoryNames.contains(fileURL.lastPathComponent) {
          enumerator.skipDescendants()
        }
        continue
      }

      guard resourceValues?.isRegularFile == true else { continue }
      guard fileURL.path.hasPrefix(rootURL.path) else { continue }

      let relativePath = String(fileURL.path.dropFirst(rootURL.path.count + 1))
      guard !relativePath.isEmpty else { continue }
      relativePaths.append(relativePath)
    }

    return projectFiles(fromRelativePaths: relativePaths)
  }
}
