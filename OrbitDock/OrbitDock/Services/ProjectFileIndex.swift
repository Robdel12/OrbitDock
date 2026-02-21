//
//  ProjectFileIndex.swift
//  OrbitDock
//
//  Async file discovery service for @mention autocomplete.
//  Uses `git ls-files` to enumerate project files with caching.
//

import Foundation

@Observable
class ProjectFileIndex {
  struct ProjectFile: Identifiable, Hashable {
    let id: String // relative path (unique within project)
    let name: String // filename (e.g. "main.rs")
    let relativePath: String // from project root (e.g. "src/main.rs")
  }

  private var cache: [String: [ProjectFile]] = [:]
  private var loading: Set<String> = []

  func files(for projectPath: String) -> [ProjectFile] {
    cache[projectPath] ?? []
  }

  func loadIfNeeded(_ projectPath: String) async {
    guard cache[projectPath] == nil, !loading.contains(projectPath) else { return }
    loading.insert(projectPath)
    defer { loading.remove(projectPath) }

    let results = await runGitLsFiles(in: projectPath)
    cache[projectPath] = results
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

  private func runGitLsFiles(in directory: String) async -> [ProjectFile] {
    #if !os(macOS)
      // TODO(server-extract): Project indexing should be provided by the server.
      _ = directory
      return []
    #else
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          let task = Process()
          task.currentDirectoryURL = URL(fileURLWithPath: directory)
          task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
          task.arguments = ["ls-files", "--cached", "--others", "--exclude-standard"]
          task.environment = ProcessInfo.processInfo.environment

          let pipe = Pipe()
          task.standardOutput = pipe
          task.standardError = FileHandle.nullDevice

          do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard task.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8)
            else {
              continuation.resume(returning: [])
              return
            }

            let files = output
              .components(separatedBy: .newlines)
              .filter { !$0.isEmpty }
              .map { path in
                let name = URL(fileURLWithPath: path).lastPathComponent
                return ProjectFile(id: path, name: name, relativePath: path)
              }

            continuation.resume(returning: files)
          } catch {
            continuation.resume(returning: [])
          }
        }
      }
    #endif
  }
}
