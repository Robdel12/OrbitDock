@testable import OrbitDock
import Foundation
import Testing

struct ProjectFileIndexTests {
  @Test func projectFilesNormalizeSortAndDedupeRelativePaths() {
    let files = ProjectFileIndex.projectFiles(fromRelativePaths: [
      "src/main.rs",
      " README.md ",
      "src\\main.rs",
      "",
    ])

    #expect(files.map(\.relativePath) == ["README.md", "src/main.rs"])
    #expect(files.map(\.name) == ["README.md", "main.rs"])
  }

  @Test func gitRelativePathsPreferTrackedAndUntrackedFilesOverIgnoredContent() throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true,
      attributes: nil
    )
    defer { try? fileManager.removeItem(at: rootURL) }

    try ".build/\n".write(
      to: rootURL.appendingPathComponent(".gitignore"),
      atomically: true,
      encoding: .utf8
    )
    try fileManager.createDirectory(
      at: rootURL.appendingPathComponent("src", isDirectory: true),
      withIntermediateDirectories: true,
      attributes: nil
    )
    try fileManager.createDirectory(
      at: rootURL.appendingPathComponent(".build", isDirectory: true),
      withIntermediateDirectories: true,
      attributes: nil
    )
    try "fn main() {}\n".write(
      to: rootURL.appendingPathComponent("src/main.rs"),
      atomically: true,
      encoding: .utf8
    )
    try "ignored\n".write(
      to: rootURL.appendingPathComponent(".build/generated.rs"),
      atomically: true,
      encoding: .utf8
    )

    try runGit(["init"], in: rootURL)
    try runGit(["add", ".gitignore", "src/main.rs"], in: rootURL)

    let relativePaths = try #require(ProjectFileIndex.gitRelativePaths(in: rootURL.path))
    #expect(relativePaths.contains("src/main.rs"))
    #expect(!relativePaths.contains(".build/generated.rs"))
  }

  private func runGit(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = directory
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }
}
