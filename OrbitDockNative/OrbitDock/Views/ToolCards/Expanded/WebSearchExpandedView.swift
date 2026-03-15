//
//  WebSearchExpandedView.swift
//  OrbitDock
//
//  Search results cards for web search tool output.
//  Features: SearchBarVisual, result cards with URL + snippet.
//

import SwiftUI

struct WebSearchExpandedView: View {
  let content: ServerRowContent

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if let input = content.inputDisplay, !input.isEmpty {
        SearchBarVisual(query: input, icon: "magnifyingglass.circle", tintColor: .toolWeb)
      }

      if let output = content.outputDisplay, !output.isEmpty {
        // Try to parse as structured results, fall back to plain text
        let results = parseSearchResults(output)
        if !results.isEmpty {
          VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(results.enumerated()), id: \.offset) { _, result in
              searchResultCard(result)
            }
          }
        } else {
          Text(output)
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
        }
      }
    }
  }

  // MARK: - Result Card

  private func searchResultCard(_ result: SearchResult) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(result.title)
        .font(.system(size: TypeScale.body, weight: .medium))
        .foregroundStyle(Color.accent)

      if let url = result.url {
        Text(url)
          .font(.system(size: TypeScale.meta, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
          .lineLimit(1)
      }

      if let snippet = result.snippet {
        Text(snippet)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(3)
      }
    }
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(Color.toolWeb)
        .frame(width: 3)
    }
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
  }

  // MARK: - Parse

  private struct SearchResult {
    let title: String
    let url: String?
    let snippet: String?
  }

  private func parseSearchResults(_ output: String) -> [SearchResult] {
    // Try JSON array format
    if let data = output.data(using: .utf8),
       let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
      return array.compactMap { dict in
        guard let title = dict["title"] as? String else { return nil }
        return SearchResult(
          title: title,
          url: dict["url"] as? String ?? dict["link"] as? String,
          snippet: dict["snippet"] as? String ?? dict["description"] as? String
        )
      }
    }

    // Try line-based format: "Title\nURL\nSnippet\n\n"
    let blocks = output.components(separatedBy: "\n\n").filter { !$0.isEmpty }
    if blocks.count > 1 {
      return blocks.compactMap { block in
        let lines = block.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let title = lines.first else { return nil }
        let url = lines.count > 1 ? lines[1] : nil
        let snippet = lines.count > 2 ? lines[2] : nil
        return SearchResult(title: title, url: url, snippet: snippet)
      }
    }

    return []
  }
}
