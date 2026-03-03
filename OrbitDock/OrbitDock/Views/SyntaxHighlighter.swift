//
//  SyntaxHighlighter.swift
//  OrbitDock
//
//  Unified syntax highlighter with NSAttributedString as the primary output.
//

import Foundation
import SwiftUI
#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

enum SyntaxHighlighter {
  private struct LineCacheEntry {
    let attributed: NSAttributedString
    var accessTick: UInt64
  }

  private static var lineCache: [String: LineCacheEntry] = [:]
  private static var lineCacheTick: UInt64 = 0
  private static let maxCacheSize = 4_000
  private static let evictionBatchSize = 512

  private static let codeFont = PlatformFont.monospacedSystemFont(ofSize: TypeScale.chatCode, weight: .regular)
  private static let defaultColor = PlatformColor(Color.syntaxText)

  private static let colorKeyword = PlatformColor(Color.syntaxKeyword)
  private static let colorString = PlatformColor(Color.syntaxString)
  private static let colorNumber = PlatformColor(Color.syntaxNumber)
  private static let colorComment = PlatformColor(Color.syntaxComment)
  private static let colorType = PlatformColor(Color.syntaxType)
  private static let colorFunction = PlatformColor(Color.syntaxFunction)
  private static let colorProperty = PlatformColor(Color.syntaxProperty)

  static func highlightNativeLine(_ line: String, language: String?) -> NSAttributedString {
    let normalizedLanguage = MarkdownLanguage.normalize(language)
    let cacheKey = "\(normalizedLanguage ?? "_"):\(line)"
    if var cached = lineCache[cacheKey] {
      cached.accessTick = nextLineCacheTick()
      lineCache[cacheKey] = cached
      return cached.attributed
    }

    let result = NSMutableAttributedString(
      string: line,
      attributes: [
        .font: codeFont,
        .foregroundColor: defaultColor,
      ]
    )

    guard let lang = normalizedLanguage, !lang.isEmpty, !line.isEmpty else {
      insertCacheValue(result, for: cacheKey)
      return result
    }

    switch lang {
      case "markdown", "text", "plaintext":
        break
      case "swift":
        highlightSwiftLine(result, line: line)
      case "javascript", "typescript":
        highlightJavaScriptLine(result, line: line)
      case "python":
        highlightPythonLine(result, line: line)
      case "json":
        highlightJSONLine(result, line: line)
      case "bash":
        highlightBashLine(result, line: line)
      case "yaml":
        highlightYAMLLine(result, line: line)
      case "sql":
        highlightSQLLine(result, line: line)
      case "go":
        highlightGoLine(result, line: line)
      case "rust":
        highlightRustLine(result, line: line)
      case "html", "xml":
        highlightHTMLLine(result, line: line)
      case "css":
        highlightCSSLine(result, line: line)
      default:
        highlightGenericLine(result, line: line)
    }

    insertCacheValue(result, for: cacheKey)
    return result
  }

  static func highlightLine(_ line: String, language: String?) -> AttributedString {
    let native = highlightNativeLine(line, language: language)
    #if os(macOS)
      if let bridged = try? AttributedString(native, including: \.appKit) { return bridged }
    #else
      if let bridged = try? AttributedString(native, including: \.uiKit) { return bridged }
    #endif
    return (try? AttributedString(native, including: \.foundation)) ?? AttributedString(line)
  }

  static func clearCache() {
    lineCache.removeAll(keepingCapacity: true)
    lineCacheTick = 0
  }

  // MARK: - Line Highlighters

  private static func highlightSwiftLine(_ result: NSMutableAttributedString, line: String) {
    let keywords = [
      "func", "let", "var", "if", "else", "guard", "return", "import", "struct", "class", "enum", "protocol",
      "extension", "private", "public", "internal", "static", "override", "final", "lazy", "weak", "mutating",
      "throws", "try", "catch", "async", "await", "some", "any", "self", "Self", "nil", "true", "false", "in", "for",
      "while", "switch", "case", "default", "break", "continue", "defer", "do", "init", "deinit", "is", "as",
    ]
    let types = [
      "String", "Int", "Double", "Float", "Bool", "Array", "Dictionary", "Set", "Optional", "View", "Any", "Void",
      "Date", "Data", "URL",
    ]

    applyLinePatterns(
      result,
      line: line,
      keywords: keywords,
      types: types,
      stringPattern: #"\"(?:[^\"\\]|\\.)*\""#,
      commentPattern: #"//.*$"#,
      numberPattern: #"\b\d+\.?\d*\b"#
    )
    applyPattern(result, code: line, pattern: #"@\w+"#, color: colorKeyword)
  }

  private static func highlightJavaScriptLine(_ result: NSMutableAttributedString, line: String) {
    let keywords = [
      "const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default",
      "break", "continue", "throw", "try", "catch", "finally", "new", "typeof", "instanceof", "this", "class",
      "extends", "static", "async", "await", "import", "export", "from", "as", "true", "false", "null", "undefined",
    ]
    let types = [
      "Array",
      "Object",
      "String",
      "Number",
      "Boolean",
      "Promise",
      "Map",
      "Set",
      "Date",
      "Error",
      "JSON",
      "console",
    ]

    applyLinePatterns(
      result,
      line: line,
      keywords: keywords,
      types: types,
      stringPattern: #"(?:\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`)"#,
      commentPattern: #"//.*$"#,
      numberPattern: #"\b\d+\.?\d*\b"#
    )
    applyPattern(result, code: line, pattern: #"=>"#, color: colorKeyword)
  }

  private static func highlightPythonLine(_ result: NSMutableAttributedString, line: String) {
    let keywords = [
      "def", "class", "if", "elif", "else", "for", "while", "try", "except", "finally", "with", "as", "import", "from",
      "return", "yield", "raise", "pass", "break", "continue", "lambda", "and", "or", "not", "in", "is", "True",
      "False",
      "None", "self", "async", "await", "global",
    ]
    let types = ["int", "str", "float", "bool", "list", "dict", "set", "tuple", "print", "range", "len", "open"]

    applyLinePatterns(
      result,
      line: line,
      keywords: keywords,
      types: types,
      stringPattern: #"(?:\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*')"#,
      commentPattern: #"#.*$"#,
      numberPattern: #"\b\d+\.?\d*\b"#
    )
    applyPattern(result, code: line, pattern: #"@\w+"#, color: colorFunction)
  }

  private static func highlightGoLine(_ result: NSMutableAttributedString, line: String) {
    let keywords = [
      "break", "case", "chan", "const", "continue", "default", "defer", "else", "for", "func", "go", "goto", "if",
      "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var", "true",
      "false", "nil",
    ]
    let types = [
      "bool", "byte", "error", "float32", "float64", "int", "int8", "int16", "int32", "int64", "rune", "string", "uint",
      "make", "new", "append", "len", "panic", "print",
    ]

    applyLinePatterns(
      result,
      line: line,
      keywords: keywords,
      types: types,
      stringPattern: #"(?:\"(?:[^\"\\]|\\.)*\"|`[^`]*`)"#,
      commentPattern: #"//.*$"#,
      numberPattern: #"\b\d+\.?\d*\b"#
    )
  }

  private static func highlightRustLine(_ result: NSMutableAttributedString, line: String) {
    let keywords = [
      "as", "async", "await", "break", "const", "continue", "else", "enum", "extern", "false", "fn", "for", "if",
      "impl",
      "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct",
      "super", "trait", "true", "type", "unsafe", "use", "where", "while",
    ]
    let types = [
      "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64", "bool", "char", "str", "String", "Vec",
      "Option",
      "Result", "Box", "Some", "None", "Ok", "Err",
    ]

    applyLinePatterns(
      result,
      line: line,
      keywords: keywords,
      types: types,
      stringPattern: #"\"(?:[^\"\\]|\\.)*\""#,
      commentPattern: #"//.*$"#,
      numberPattern: #"\b\d+\.?\d*\b"#
    )
    applyPattern(result, code: line, pattern: #"\b\w+!"#, color: colorFunction)
  }

  private static func highlightHTMLLine(_ result: NSMutableAttributedString, line: String) {
    applyPattern(result, code: line, pattern: #"</?[a-zA-Z][a-zA-Z0-9]*"#, color: colorKeyword)
    applyPattern(result, code: line, pattern: #"\b[a-zA-Z-]+(?==)"#, color: colorProperty)
    applyPattern(result, code: line, pattern: #"\"[^\"]*\""#, color: colorString)
    applyPattern(result, code: line, pattern: #"<!--.*-->"#, color: colorComment)
  }

  private static func highlightCSSLine(_ result: NSMutableAttributedString, line: String) {
    applyPattern(result, code: line, pattern: #"[.#]?[a-zA-Z_-][a-zA-Z0-9_-]*(?=\s*\{)"#, color: colorFunction)
    applyPattern(result, code: line, pattern: #"[a-zA-Z-]+(?=\s*:)"#, color: colorProperty)
    applyPattern(result, code: line, pattern: #"\b\d+\.?\d*(px|em|rem|%|vh|vw)?\b"#, color: colorNumber)
    applyPattern(result, code: line, pattern: #"/\*.*\*/"#, color: colorComment)
  }

  private static func highlightJSONLine(_ result: NSMutableAttributedString, line: String) {
    applyPattern(result, code: line, pattern: #"\"[^\"]+\"\s*(?=:)"#, color: colorProperty)
    applyPattern(result, code: line, pattern: #":\s*(\"[^\"]*\")"#, color: colorString, group: 1)
    applyPattern(result, code: line, pattern: #":\s*(-?\d+\.?\d*)"#, color: colorNumber, group: 1)
    applyPattern(result, code: line, pattern: #"\b(true|false|null)\b"#, color: colorKeyword)
  }

  private static func highlightBashLine(_ result: NSMutableAttributedString, line: String) {
    let keywords = [
      "if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done", "in", "function",
      "return", "exit", "break", "continue", "export", "local",
    ]
    for keyword in keywords {
      applyPattern(result, code: line, pattern: "\\b\(keyword)\\b", color: colorKeyword)
    }
    applyPattern(result, code: line, pattern: #"#.*$"#, color: colorComment)
    applyPattern(result, code: line, pattern: #"(?:\"(?:[^\"\\]|\\.)*\"|'[^']*')"#, color: colorString)
    applyPattern(result, code: line, pattern: #"\$\{?\w+\}?"#, color: colorProperty)
  }

  private static func highlightYAMLLine(_ result: NSMutableAttributedString, line: String) {
    applyPattern(result, code: line, pattern: #"^[\s-]*[a-zA-Z_][a-zA-Z0-9_]*(?=\s*:)"#, color: colorProperty)
    applyPattern(result, code: line, pattern: #"(?:\"[^\"]*\"|'[^']*')"#, color: colorString)
    applyPattern(
      result,
      code: line,
      pattern: #"\b(true|false|yes|no|null|~)\b"#,
      color: colorKeyword,
      caseInsensitive: true
    )
    applyPattern(result, code: line, pattern: #"#.*$"#, color: colorComment)
  }

  private static func highlightSQLLine(_ result: NSMutableAttributedString, line: String) {
    let keywords = [
      "SELECT", "FROM", "WHERE", "AND", "OR", "JOIN", "LEFT", "RIGHT", "INNER", "ON", "GROUP", "BY", "ORDER", "ASC",
      "DESC", "LIMIT", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "DROP", "ALTER",
    ]
    for keyword in keywords {
      applyPattern(result, code: line, pattern: "\\b\(keyword)\\b", color: colorKeyword, caseInsensitive: true)
    }
    applyPattern(result, code: line, pattern: #"'[^']*'"#, color: colorString)
    applyPattern(result, code: line, pattern: #"--.*$"#, color: colorComment)
  }

  private static func highlightGenericLine(_ result: NSMutableAttributedString, line: String) {
    applyPattern(result, code: line, pattern: #"(?:\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*')"#, color: colorString)
    applyPattern(result, code: line, pattern: #"\b\d+\.?\d*\b"#, color: colorNumber)
    applyPattern(result, code: line, pattern: #"//.*$"#, color: colorComment)
    applyPattern(result, code: line, pattern: #"#.*$"#, color: colorComment)
  }

  // MARK: - Regex Helpers

  private static func applyLinePatterns(
    _ result: NSMutableAttributedString,
    line: String,
    keywords: [String],
    types: [String],
    stringPattern: String,
    commentPattern: String,
    numberPattern: String
  ) {
    applyPattern(result, code: line, pattern: commentPattern, color: colorComment)
    applyPattern(result, code: line, pattern: stringPattern, color: colorString)
    for keyword in keywords {
      applyPattern(
        result,
        code: line,
        pattern: "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b",
        color: colorKeyword
      )
    }
    for type in types {
      applyPattern(
        result,
        code: line,
        pattern: "\\b\(NSRegularExpression.escapedPattern(for: type))\\b",
        color: colorType
      )
    }
    applyPattern(result, code: line, pattern: numberPattern, color: colorNumber)
  }

  private static func applyPattern(
    _ result: NSMutableAttributedString,
    code: String,
    pattern: String,
    color: PlatformColor,
    group: Int = 0,
    caseInsensitive: Bool = false
  ) {
    var options: NSRegularExpression.Options = [.anchorsMatchLines]
    if caseInsensitive { options.insert(.caseInsensitive) }

    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
    let nsString = code as NSString
    let matches = regex.matches(in: code, range: NSRange(location: 0, length: nsString.length))

    for match in matches {
      let targetRange = group > 0 && match.numberOfRanges > group ? match.range(at: group) : match.range
      guard targetRange.location != NSNotFound else { continue }
      result.addAttribute(.foregroundColor, value: color, range: targetRange)
    }
  }

  // MARK: - Cache Helpers

  private static func nextLineCacheTick() -> UInt64 {
    lineCacheTick &+= 1
    return lineCacheTick
  }

  private static func insertCacheValue(_ value: NSAttributedString, for key: String) {
    if lineCache[key] == nil {
      evictIfNeeded()
    }

    lineCache[key] = LineCacheEntry(attributed: value, accessTick: nextLineCacheTick())
  }

  private static func evictIfNeeded() {
    guard lineCache.count >= maxCacheSize else { return }
    let toEvict = min(evictionBatchSize, lineCache.count)
    guard toEvict > 0 else { return }

    let keysToEvict = lineCache
      .sorted { lhs, rhs in
        lhs.value.accessTick < rhs.value.accessTick
      }
      .prefix(toEvict)
      .map(\.key)
    for key in keysToEvict {
      lineCache.removeValue(forKey: key)
    }
  }
}
