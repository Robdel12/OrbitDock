import Foundation

enum ControlDeckTextEditing {
  static func trailingTokenQuery(
    in text: String,
    prefix: Character,
    requireWhitespaceBoundaryBeforePrefix: Bool = false
  ) -> String? {
    guard let range = trailingTokenRange(
      in: text,
      prefix: prefix,
      requireWhitespaceBoundaryBeforePrefix: requireWhitespaceBoundaryBeforePrefix
    ) else { return nil }

    let queryStart = text.index(after: range.lowerBound)
    return String(text[queryStart ..< range.upperBound])
  }

  static func replacingTrailingToken(
    in text: String,
    prefix: Character,
    with replacement: String,
    appendWhenMissing: Bool = true
  ) -> String {
    guard let range = trailingTokenRange(in: text, prefix: prefix) else {
      return appendWhenMissing ? text + replacement : text
    }
    var updated = text
    updated.replaceSubrange(range, with: replacement)
    return updated
  }

  static func trailingTokenRange(
    in text: String,
    prefix: Character,
    requireWhitespaceBoundaryBeforePrefix: Bool = false
  ) -> Range<String.Index>? {
    guard let prefixIndex = text.lastIndex(of: prefix) else { return nil }

    if requireWhitespaceBoundaryBeforePrefix, prefixIndex != text.startIndex {
      let charBefore = text[text.index(before: prefixIndex)]
      guard charBefore.isWhitespace else { return nil }
    }

    let tokenStart = text.index(after: prefixIndex)
    let suffix = text[tokenStart...]
    guard !suffix.contains(where: \.isWhitespace) else { return nil }
    return prefixIndex ..< text.endIndex
  }

  static func inlineSkillNames(in text: String, availableSkillNames: [String]) -> [String] {
    guard !text.isEmpty, !availableSkillNames.isEmpty else { return [] }

    let availableByLowerName = availableSkillNames.reduce(into: [String: String]()) { dict, name in
      let key = name.lowercased()
      if dict[key] == nil {
        dict[key] = name
      }
    }

    var seen: Set<String> = []
    var matches: [String] = []
    var index = text.startIndex

    while index < text.endIndex {
      guard text[index] == "$" else {
        index = text.index(after: index)
        continue
      }

      if index != text.startIndex {
        let charBefore = text[text.index(before: index)]
        if charBefore.isLetter || charBefore.isNumber {
          index = text.index(after: index)
          continue
        }
      }

      let tokenStart = text.index(after: index)
      guard tokenStart < text.endIndex else { break }

      var tokenEnd = tokenStart
      while tokenEnd < text.endIndex, isSkillTokenCharacter(text[tokenEnd]) {
        tokenEnd = text.index(after: tokenEnd)
      }

      guard tokenEnd > tokenStart else {
        index = tokenStart
        continue
      }

      let rawToken = String(text[tokenStart ..< tokenEnd]).lowercased()
      if let canonical = canonicalSkillName(
        for: rawToken,
        availableByLowerName: availableByLowerName
      ),
        seen.insert(canonical).inserted
      {
        matches.append(canonical)
      }

      index = tokenEnd
    }

    return matches
  }

  private static func isSkillTokenCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
  }

  private static func canonicalSkillName(
    for rawToken: String,
    availableByLowerName: [String: String]
  ) -> String? {
    if let exact = availableByLowerName[rawToken] {
      return exact
    }

    var trimmed = rawToken
    while let last = trimmed.last, trailingSkillPunctuation.contains(last) {
      trimmed.removeLast()
      guard !trimmed.isEmpty else { return nil }
      if let canonical = availableByLowerName[trimmed] {
        return canonical
      }
    }

    return nil
  }

  private static let trailingSkillPunctuation: Set<Character> = [".", ",", "!", "?", ":", ";"]
}
