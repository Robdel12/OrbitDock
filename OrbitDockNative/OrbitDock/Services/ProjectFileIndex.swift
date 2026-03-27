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

    // Keep file mentions and picker surfaces working with a sandbox-safe
    // filesystem scan until the server-backed index replaces this client cache.
    cache[projectPath] = await Self.scanWithFileManager(in: projectPath)
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

  private nonisolated static func scanWithFileManager(in directory: String) async -> [ProjectFile] {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let rootURL = URL(fileURLWithPath: directory, isDirectory: true)
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
          at: rootURL,
          includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
          options: [.skipsHiddenFiles, .skipsPackageDescendants],
          errorHandler: nil
        ) else {
          continuation.resume(returning: [])
          return
        }

        let excludedDirectoryNames: Set<String> = [
          ".git", ".build", "node_modules", "Pods", "DerivedData",
        ]
        let maxFiles = 6_000
        var files: [ProjectFile] = []
        files.reserveCapacity(1_500)

        for case let fileURL as URL in enumerator {
          if files.count >= maxFiles {
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
          let name = fileURL.lastPathComponent
          files.append(ProjectFile(id: relativePath, name: name, relativePath: relativePath))
        }

        files.sort { $0.relativePath < $1.relativePath }
        continuation.resume(returning: files)
      }
    }
  }
}
