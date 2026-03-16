import Foundation

enum ReviewMessageFormatter {
  static func format(comments: [ServerReviewComment], model: DiffModel?) -> String? {
    guard !comments.isEmpty else { return nil }

    var fileOrder: [String] = []
    var grouped: [String: [ServerReviewComment]] = [:]
    for comment in comments {
      if grouped[comment.filePath] == nil {
        fileOrder.append(comment.filePath)
      }
      grouped[comment.filePath, default: []].append(comment)
    }

    var lines: [String] = ["## Code Review Feedback", ""]

    for filePath in fileOrder {
      let fileComments = grouped[filePath] ?? []
      let ext = filePath.components(separatedBy: ".").last ?? ""
      lines.append("### \(filePath)")

      for comment in fileComments.sorted(by: { $0.lineStart < $1.lineStart }) {
        let lineRef = if let end = comment.lineEnd, end != comment.lineStart {
          "Lines \(comment.lineStart)–\(end)"
        } else {
          "Line \(comment.lineStart)"
        }

        let tagSuffix = comment.tag.map { " [\($0.rawValue)]" } ?? ""
        lines.append("")
        lines.append("**\(lineRef)**\(tagSuffix):")

        if let diffContent = extractDiffLines(
          model: model,
          filePath: filePath,
          lineStart: Int(comment.lineStart),
          lineEnd: comment.lineEnd.map { Int($0) }
        ) {
          lines.append("```\(ext)")
          lines.append(diffContent)
          lines.append("```")
        }

        lines.append("> \(comment.body)")
      }

      lines.append("")
    }

    let ids = comments.map(\.id).joined(separator: ",")
    lines.append("<!-- review-comment-ids: \(ids) -->")

    return lines.joined(separator: "\n")
  }

  static func extractDiffLines(
    model: DiffModel?,
    filePath: String,
    lineStart: Int,
    lineEnd: Int?
  ) -> String? {
    guard let model,
          let file = model.files.first(where: { $0.newPath == filePath })
    else {
      return nil
    }

    let endLine = lineEnd ?? lineStart
    var extracted: [String] = []

    for hunk in file.hunks {
      for line in hunk.lines {
        guard let newLineNum = line.newLineNum else {
          if !extracted.isEmpty, line.type == .removed {
            extracted.append("\(line.prefix)\(line.content)")
          }
          continue
        }

        if newLineNum >= lineStart, newLineNum <= endLine {
          extracted.append("\(line.prefix)\(line.content)")
        }
      }
    }

    return extracted.isEmpty ? nil : extracted.joined(separator: "\n")
  }
}
