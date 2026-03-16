//
//  WebSearchExpandedView.swift
//  OrbitDock
//
//  Search results cards for web search tool output.
//  Features: SearchBarVisual, domain badges, numbered results, query highlighting.
//

import SwiftUI

struct WebSearchExpandedView: View {
  let content: ServerRowContent

  private var query: String {
    content.inputDisplay ?? ""
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if !query.isEmpty {
        SearchBarVisual(query: query, icon: "magnifyingglass.circle", tintColor: .toolWeb)
      }

      if let output = content.outputDisplay, !output.isEmpty {
        // Try to parse as structured results, fall back to plain text
        let results = parseSearchResults(output)
        if !results.isEmpty {
          VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(results.enumerated()), id: \.offset) { index, result in
              searchResultCard(result, number: index + 1)
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

  private func searchResultCard(_ result: SearchResult, number: Int) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      // Domain badge
      if let url = result.url, let domain = domainFrom(url) {
        Text(domain)
          .font(.system(size: TypeScale.mini, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
          .padding(.horizontal, Spacing.sm_)
          .padding(.vertical, 1)
          .background(Color.textQuaternary.opacity(OpacityTier.tint), in: Capsule())
      }

      // Numbered title
      HStack(alignment: .firstTextBaseline, spacing: Spacing.sm_) {
        Text("\(number).")
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textQuaternary)
        Text(result.title)
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.accent)
      }

      if let url = result.url {
        Text(url)
          .font(.system(size: TypeScale.meta, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
          .lineLimit(1)
      }

      if let snippet = result.snippet, !query.isEmpty {
        Text(highlightQuery(in: snippet, query: query))
          .lineLimit(3)
      } else if let snippet = result.snippet {
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

  // MARK: - Helpers

  private func domainFrom(_ url: String) -> String? {
    URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "")
  }

  private func highlightQuery(in text: String, query: String) -> AttributedString {
    var result = AttributedString(text)
    result.font = .system(size: TypeScale.caption)
    result.foregroundColor = Color.textTertiary
    let words = query.lowercased().split(separator: " ")
    let lowered = text.lowercased()
    for word in words {
      var searchStart = lowered.startIndex
      while let range = lowered.range(of: word, range: searchStart ..< lowered.endIndex) {
        if let attrRange = Range(range, in: result) {
          result[attrRange].backgroundColor = Color.toolWeb.opacity(0.15)
          result[attrRange].foregroundColor = Color.toolWeb
        }
        searchStart = range.upperBound
      }
    }
    return result
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
       let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    {
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
