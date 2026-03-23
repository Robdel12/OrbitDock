import Foundation
@testable import OrbitDock
import Testing

struct DiffModelTests {
  // MARK: - Server-merged cumulative diffs (multiple hunks per file)

  @Test func parsesMultipleHunksInSingleFileBlock() {
    // Server merges same-file edits across turns into one diff --git block with multiple @@ hunks
    let diff = makeDiff(
      "diff --git a/Sources/App.swift b/Sources/App.swift",
      "--- a/Sources/App.swift",
      "+++ b/Sources/App.swift",
      "@@ -1,3 +1,3 @@",
      " let a = 1",
      "-let b = 2",
      "+let b = 42",
      " let c = 3",
      "@@ -10,3 +10,4 @@",
      " let x = 10",
      "-let y = 11",
      "+let y = 99",
      "+let z = 12",
      " let w = 13"
    )

    let model = DiffModel.parse(unifiedDiff: diff)

    #expect(model.files.count == 1)
    #expect(model.files[0].id == "Sources/App.swift")
    #expect(model.files[0].hunks.count == 2)

    #expect(model.files[0].hunks[0].oldStart == 1)
    #expect(model.files[0].hunks[1].oldStart == 10)

    let stats = model.files[0].stats
    #expect(stats.additions == 3) // +let b = 42, +let y = 99, +let z = 12
    #expect(stats.deletions == 2) // -let b = 2, -let y = 11
  }

  @Test func preservesLineNumbersAcrossMultipleHunks() {
    let diff = makeDiff(
      "diff --git a/file.js b/file.js",
      "--- a/file.js",
      "+++ b/file.js",
      "@@ -5,3 +5,3 @@",
      " const a = 1",
      "-const b = 2",
      "+const b = 3",
      " const c = 4",
      "@@ -20,2 +20,3 @@",
      " const x = 10",
      "+const y = 11",
      " const z = 12"
    )

    let model = DiffModel.parse(unifiedDiff: diff)
    let file = model.files[0]

    #expect(file.hunks.count == 2)

    let hunk1Lines = file.hunks[0].lines
    #expect(hunk1Lines[0].oldLineNum == 5)
    #expect(hunk1Lines[0].newLineNum == 5)

    let hunk2Lines = file.hunks[1].lines
    #expect(hunk2Lines[0].oldLineNum == 20)
    #expect(hunk2Lines[0].newLineNum == 20)
    #expect(hunk2Lines[1].newLineNum == 21) // the added line
  }

  @Test func parsesMultipleFilesEachWithOwnHunks() {
    let diff = makeDiff(
      "diff --git a/a.swift b/a.swift",
      "--- a/a.swift",
      "+++ b/a.swift",
      "@@ -1,2 +1,2 @@",
      "-old a",
      "+new a",
      " ctx",
      "@@ -10,2 +10,3 @@",
      " ctx2",
      "+added in a",
      " ctx3",
      "diff --git a/b.swift b/b.swift",
      "--- a/b.swift",
      "+++ b/b.swift",
      "@@ -1,2 +1,2 @@",
      "-old b",
      "+new b",
      " ctx"
    )

    let model = DiffModel.parse(unifiedDiff: diff)

    #expect(model.files.count == 2)
    #expect(model.files[0].id == "a.swift")
    #expect(model.files[1].id == "b.swift")

    #expect(model.files[0].hunks.count == 2)
    #expect(model.files[1].hunks.count == 1)
  }

  // MARK: - Single file parsing

  @Test func parsesSingleFileDiffCorrectly() {
    let diff = makeDiff(
      "diff --git a/main.rs b/main.rs",
      "--- a/main.rs",
      "+++ b/main.rs",
      "@@ -1,3 +1,3 @@",
      " fn main() {",
      "-    println!(\"hello\");",
      "+    println!(\"world\");",
      " }"
    )

    let model = DiffModel.parse(unifiedDiff: diff)
    #expect(model.files.count == 1)
    #expect(model.files[0].hunks.count == 1)
    #expect(model.files[0].hunks[0].lines.count == 4)
    #expect(model.files[0].stats.additions == 1)
    #expect(model.files[0].stats.deletions == 1)
  }

  // MARK: - Helpers

  private func makeDiff(_ lines: String...) -> String {
    lines.joined(separator: "\n")
  }
}
