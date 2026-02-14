//
//  SyntaxHighlighter.swift
//  OrbitDock
//
//  Syntax highlighting for code blocks. Uses Color.syntax* from Theme.swift.
//

import SwiftUI

enum SyntaxHighlighter {
  /// Highlight a single line (for line-by-line rendering)
  static func highlightLine(_ line: String, language: String?) -> AttributedString {
    var result = AttributedString(line)
    result.foregroundColor = Color.syntaxText

    guard let lang = language, !line.isEmpty else { return result }

    switch lang {
      case "swift":
        highlightSwiftLine(&result, line: line)
      case "javascript", "typescript":
        highlightJavaScriptLine(&result, line: line)
      case "python":
        highlightPythonLine(&result, line: line)
      case "json":
        highlightJSONLine(&result, line: line)
      case "bash":
        highlightBashLine(&result, line: line)
      case "yaml":
        highlightYAMLLine(&result, line: line)
      case "sql":
        highlightSQLLine(&result, line: line)
      case "go":
        highlightGoLine(&result, line: line)
      case "rust":
        highlightRustLine(&result, line: line)
      case "html", "xml":
        highlightHTMLLine(&result, line: line)
      case "css":
        highlightCSSLine(&result, line: line)
      default:
        highlightGenericLine(&result, line: line)
    }

    return result
  }

  /// Full code highlighting (for backwards compat)
  static func highlight(_ code: String, language: String?) -> AttributedString {
    var result = AttributedString(code)
    result.foregroundColor = Color.syntaxText

    guard let lang = language else { return result }

    switch lang {
      case "swift":
        highlightSwift(&result, code: code)
      case "javascript", "typescript":
        highlightJavaScript(&result, code: code)
      case "python":
        highlightPython(&result, code: code)
      case "json":
        highlightJSON(&result, code: code)
      case "bash":
        highlightBash(&result, code: code)
      case "yaml":
        highlightYAML(&result, code: code)
      case "sql":
        highlightSQL(&result, code: code)
      case "go":
        highlightGo(&result, code: code)
      case "rust":
        highlightRust(&result, code: code)
      case "html", "xml":
        highlightHTML(&result, code: code)
      case "css":
        highlightCSS(&result, code: code)
      default:
        highlightGeneric(&result, code: code)
    }

    return result
  }

  // MARK: - Line-based highlighters

  private static func highlightSwiftLine(_ result: inout AttributedString, line: String) {
    let keywords = [
      "func",
      "let",
      "var",
      "if",
      "else",
      "guard",
      "return",
      "import",
      "struct",
      "class",
      "enum",
      "protocol",
      "extension",
      "private",
      "public",
      "internal",
      "static",
      "override",
      "final",
      "lazy",
      "weak",
      "mutating",
      "throws",
      "try",
      "catch",
      "async",
      "await",
      "some",
      "any",
      "self",
      "Self",
      "nil",
      "true",
      "false",
      "in",
      "for",
      "while",
      "switch",
      "case",
      "default",
      "break",
      "continue",
      "defer",
      "do",
      "init",
      "deinit",
      "is",
      "as",
    ]
    let types = [
      "String",
      "Int",
      "Double",
      "Float",
      "Bool",
      "Array",
      "Dictionary",
      "Set",
      "Optional",
      "View",
      "Any",
      "Void",
      "Date",
      "Data",
      "URL",
    ]

    applyLinePatterns(
      &result,
      line: line,
      keywords: keywords,
      types: types,
      stringPattern: #"\"(?:[^\"\\]|\\.)*\""#,
      commentPattern: #"//.*$"#,
      numberPattern: #"\b\d+\.?\d*\b"#
    )
    applyPattern(&result, code: line, pattern: #"@\w+"#, color: Color.syntaxKeyword)
  }

  private static func highlightJavaScriptLine(_ result: inout AttributedString, line: String) {
    let keywords = [
      "const",
      "let",
      "var",
      "function",
      "return",
      "if",
      "else",
      "for",
      "while",
      "do",
      "switch",
      "case",
      "default",
      "break",
      "continue",
      "throw",
      "try",
      "catch",
      "finally",
      "new",
      "typeof",
      "instanceof",
      "this",
      "class",
      "extends",
      "static",
      "async",
      "await",
      "import",
      "export",
      "from",
      "as",
      "true",
      "false",
      "null",
      "undefined",
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
      &result,
      line: line,
      keywords: keywords,
      types: types,
      stringPattern: #"(?:\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`)"#,
      commentPattern: #"//.*$"#,
      numberPattern: #"\b\d+\.?\d*\b"#
    )
    applyPattern(&result, code: line, pattern: #"=>"#, color: Color.syntaxKeyword)
  }

  private static func highlightPythonLine(_ result: inout AttributedString, line: String) {
    let keywords = [
      "def",
      "class",
      "if",
      "elif",
      "else",
      "for",
      "while",
      "try",
      "except",
      "finally",
      "with",
      "as",
      "import",
      "from",
      "return",
      "yield",
      "raise",
      "pass",
      "break",
      "continue",
      "lambda",
      "and",
      "or",
      "not",
      "in",
      "is",
      "True",
      "False",
      "None",
      "self",
      "async",
      "await",
      "global",
    ]
    let types = ["int", "str", "float", "bool", "list", "dict", "set", "tuple", "print", "range", "len", "open"]

    applyLinePatterns(
      &result,
      line: line,
      keywords: keywords,
      types: types,
      stringPattern: #"(?:\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*')"#,
      commentPattern: #"#.*$"#,
      numberPattern: #"\b\d+\.?\d*\b"#
    )
    applyPattern(&result, code: line, pattern: #"@\w+"#, color: Color.syntaxFunction)
  }

  private static func highlightGoLine(_ result: inout AttributedString, line: String) {
    let keywords = [
      "break",
      "case",
      "chan",
      "const",
      "continue",
      "default",
      "defer",
      "else",
      "for",
      "func",
      "go",
      "goto",
      "if",
      "import",
      "interface",
      "map",
      "package",
      "range",
      "return",
      "select",
      "struct",
      "switch",
      "type",
      "var",
      "true",
      "false",
      "nil",
    ]
    let types = [
      "bool",
      "byte",
      "error",
      "float32",
      "float64",
      "int",
      "int8",
      "int16",
      "int32",
      "int64",
      "rune",
      "string",
      "uint",
      "make",
      "new",
      "append",
      "len",
      "panic",
      "print",
    ]

    applyLinePatterns(
      &result,
      line: line,
      keywords: keywords,
      types: types,
      stringPattern: #"(?:\"(?:[^\"\\]|\\.)*\"|`[^`]*`)"#,
      commentPattern: #"//.*$"#,
      numberPattern: #"\b\d+\.?\d*\b"#
    )
  }

  private static func highlightRustLine(_ result: inout AttributedString, line: String) {
    let keywords = [
      "as",
      "async",
      "await",
      "break",
      "const",
      "continue",
      "else",
      "enum",
      "extern",
      "false",
      "fn",
      "for",
      "if",
      "impl",
      "in",
      "let",
      "loop",
      "match",
      "mod",
      "move",
      "mut",
      "pub",
      "ref",
      "return",
      "self",
      "Self",
      "static",
      "struct",
      "super",
      "trait",
      "true",
      "type",
      "unsafe",
      "use",
      "where",
      "while",
    ]
    let types = [
      "i8",
      "i16",
      "i32",
      "i64",
      "u8",
      "u16",
      "u32",
      "u64",
      "f32",
      "f64",
      "bool",
      "char",
      "str",
      "String",
      "Vec",
      "Option",
      "Result",
      "Box",
      "Some",
      "None",
      "Ok",
      "Err",
    ]

    applyLinePatterns(
      &result,
      line: line,
      keywords: keywords,
      types: types,
      stringPattern: #"\"(?:[^\"\\]|\\.)*\""#,
      commentPattern: #"//.*$"#,
      numberPattern: #"\b\d+\.?\d*\b"#
    )
    applyPattern(&result, code: line, pattern: #"\b\w+!"#, color: Color.syntaxFunction)
  }

  private static func highlightHTMLLine(_ result: inout AttributedString, line: String) {
    applyPattern(&result, code: line, pattern: #"</?[a-zA-Z][a-zA-Z0-9]*"#, color: Color.syntaxKeyword)
    applyPattern(&result, code: line, pattern: #"\b[a-zA-Z-]+(?==)"#, color: Color.syntaxProperty)
    applyPattern(&result, code: line, pattern: #"\"[^\"]*\""#, color: Color.syntaxString)
    applyPattern(&result, code: line, pattern: #"<!--.*-->"#, color: Color.syntaxComment)
  }

  private static func highlightCSSLine(_ result: inout AttributedString, line: String) {
    applyPattern(&result, code: line, pattern: #"[.#]?[a-zA-Z_-][a-zA-Z0-9_-]*(?=\s*\{)"#, color: Color.syntaxFunction)
    applyPattern(&result, code: line, pattern: #"[a-zA-Z-]+(?=\s*:)"#, color: Color.syntaxProperty)
    applyPattern(&result, code: line, pattern: #"\b\d+\.?\d*(px|em|rem|%|vh|vw)?\b"#, color: Color.syntaxNumber)
    applyPattern(&result, code: line, pattern: #"/\*.*\*/"#, color: Color.syntaxComment)
  }

  private static func highlightJSONLine(_ result: inout AttributedString, line: String) {
    applyPattern(&result, code: line, pattern: #"\"[^\"]+\"\s*(?=:)"#, color: Color.syntaxProperty)
    applyPattern(&result, code: line, pattern: #":\s*(\"[^\"]*\")"#, color: Color.syntaxString, group: 1)
    applyPattern(&result, code: line, pattern: #":\s*(-?\d+\.?\d*)"#, color: Color.syntaxNumber, group: 1)
    applyPattern(&result, code: line, pattern: #"\b(true|false|null)\b"#, color: Color.syntaxKeyword)
  }

  private static func highlightBashLine(_ result: inout AttributedString, line: String) {
    let keywords = [
      "if",
      "then",
      "else",
      "elif",
      "fi",
      "case",
      "esac",
      "for",
      "while",
      "until",
      "do",
      "done",
      "in",
      "function",
      "return",
      "exit",
      "break",
      "continue",
      "export",
      "local",
    ]
    for keyword in keywords {
      applyPattern(&result, code: line, pattern: "\\b\(keyword)\\b", color: Color.syntaxKeyword)
    }
    applyPattern(&result, code: line, pattern: #"#.*$"#, color: Color.syntaxComment)
    applyPattern(&result, code: line, pattern: #"(?:\"(?:[^\"\\]|\\.)*\"|'[^']*')"#, color: Color.syntaxString)
    applyPattern(&result, code: line, pattern: #"\$\{?\w+\}?"#, color: Color.syntaxProperty)
  }

  private static func highlightYAMLLine(_ result: inout AttributedString, line: String) {
    applyPattern(&result, code: line, pattern: #"^[\s-]*[a-zA-Z_][a-zA-Z0-9_]*(?=\s*:)"#, color: Color.syntaxProperty)
    applyPattern(&result, code: line, pattern: #"(?:\"[^\"]*\"|'[^']*')"#, color: Color.syntaxString)
    applyPattern(
      &result,
      code: line,
      pattern: #"\b(true|false|yes|no|null|~)\b"#,
      color: Color.syntaxKeyword,
      caseInsensitive: true
    )
    applyPattern(&result, code: line, pattern: #"#.*$"#, color: Color.syntaxComment)
  }

  private static func highlightSQLLine(_ result: inout AttributedString, line: String) {
    let keywords = [
      "SELECT",
      "FROM",
      "WHERE",
      "AND",
      "OR",
      "JOIN",
      "LEFT",
      "RIGHT",
      "INNER",
      "ON",
      "GROUP",
      "BY",
      "ORDER",
      "ASC",
      "DESC",
      "LIMIT",
      "INSERT",
      "INTO",
      "VALUES",
      "UPDATE",
      "SET",
      "DELETE",
      "CREATE",
      "TABLE",
      "DROP",
      "ALTER",
    ]
    for keyword in keywords {
      applyPattern(&result, code: line, pattern: "\\b\(keyword)\\b", color: Color.syntaxKeyword, caseInsensitive: true)
    }
    applyPattern(&result, code: line, pattern: #"'[^']*'"#, color: Color.syntaxString)
    applyPattern(&result, code: line, pattern: #"--.*$"#, color: Color.syntaxComment)
  }

  private static func highlightGenericLine(_ result: inout AttributedString, line: String) {
    applyPattern(
      &result,
      code: line,
      pattern: #"(?:\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*')"#,
      color: Color.syntaxString
    )
    applyPattern(&result, code: line, pattern: #"\b\d+\.?\d*\b"#, color: Color.syntaxNumber)
    applyPattern(&result, code: line, pattern: #"//.*$"#, color: Color.syntaxComment)
    applyPattern(&result, code: line, pattern: #"#.*$"#, color: Color.syntaxComment)
  }

  // MARK: - Full code highlighters (for backwards compat)

  private static func highlightSwift(_ result: inout AttributedString, code: String) {
    let keywords = [
      "func",
      "let",
      "var",
      "if",
      "else",
      "guard",
      "return",
      "import",
      "struct",
      "class",
      "enum",
      "protocol",
      "extension",
      "private",
      "public",
      "internal",
      "static",
      "override",
      "final",
      "lazy",
      "weak",
      "mutating",
      "throws",
      "try",
      "catch",
      "async",
      "await",
      "some",
      "any",
      "self",
      "Self",
      "nil",
      "true",
      "false",
      "in",
      "for",
      "while",
      "switch",
      "case",
      "default",
      "break",
      "continue",
      "defer",
      "do",
      "init",
      "deinit",
      "is",
      "as",
      "@State",
      "@Binding",
      "@Published",
      "@ObservedObject",
      "@StateObject",
      "@Environment",
      "@MainActor",
    ]
    let types = [
      "String",
      "Int",
      "Double",
      "Float",
      "Bool",
      "Array",
      "Dictionary",
      "Set",
      "Optional",
      "View",
      "Any",
      "Void",
      "Date",
      "Data",
      "URL",
    ]

    applyPatterns(
      &result,
      code: code,
      keywords: keywords,
      types: types,
      stringPattern: #"\"(?:[^\"\\]|\\.)*\""#,
      commentPatterns: [#"//.*$"#, #"/\*[\s\S]*?\*/"#],
      numberPattern: #"\b\d+\.?\d*\b"#
    )
    applyPattern(&result, code: code, pattern: #"@\w+"#, color: Color.syntaxKeyword)
  }

  private static func highlightJavaScript(_ result: inout AttributedString, code: String) {
    let keywords = [
      "const",
      "let",
      "var",
      "function",
      "return",
      "if",
      "else",
      "for",
      "while",
      "do",
      "switch",
      "case",
      "default",
      "break",
      "continue",
      "throw",
      "try",
      "catch",
      "finally",
      "new",
      "typeof",
      "instanceof",
      "this",
      "class",
      "extends",
      "static",
      "async",
      "await",
      "import",
      "export",
      "from",
      "as",
      "true",
      "false",
      "null",
      "undefined",
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

    applyPatterns(
      &result,
      code: code,
      keywords: keywords,
      types: types,
      stringPattern: #"(?:\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`)"#,
      commentPatterns: [#"//.*$"#, #"/\*[\s\S]*?\*/"#],
      numberPattern: #"\b\d+\.?\d*\b"#
    )
    applyPattern(&result, code: code, pattern: #"=>"#, color: Color.syntaxKeyword)
  }

  private static func highlightPython(_ result: inout AttributedString, code: String) {
    let keywords = [
      "def",
      "class",
      "if",
      "elif",
      "else",
      "for",
      "while",
      "try",
      "except",
      "finally",
      "with",
      "as",
      "import",
      "from",
      "return",
      "yield",
      "raise",
      "pass",
      "break",
      "continue",
      "lambda",
      "and",
      "or",
      "not",
      "in",
      "is",
      "True",
      "False",
      "None",
      "self",
      "async",
      "await",
      "global",
    ]
    let types = ["int", "str", "float", "bool", "list", "dict", "set", "tuple", "print", "range", "len", "open"]

    applyPatterns(
      &result,
      code: code,
      keywords: keywords,
      types: types,
      stringPattern: #"(?:\"\"\"[\s\S]*?\"\"\"|'''[\s\S]*?'''|\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*')"#,
      commentPatterns: [#"#.*$"#],
      numberPattern: #"\b\d+\.?\d*\b"#
    )
    applyPattern(&result, code: code, pattern: #"@\w+"#, color: Color.syntaxFunction)
  }

  private static func highlightGo(_ result: inout AttributedString, code: String) {
    let keywords = [
      "break",
      "case",
      "chan",
      "const",
      "continue",
      "default",
      "defer",
      "else",
      "for",
      "func",
      "go",
      "goto",
      "if",
      "import",
      "interface",
      "map",
      "package",
      "range",
      "return",
      "select",
      "struct",
      "switch",
      "type",
      "var",
      "true",
      "false",
      "nil",
    ]
    let types = [
      "bool",
      "byte",
      "error",
      "float32",
      "float64",
      "int",
      "int8",
      "int16",
      "int32",
      "int64",
      "rune",
      "string",
      "uint",
      "make",
      "new",
      "append",
      "len",
      "panic",
      "print",
    ]

    applyPatterns(
      &result,
      code: code,
      keywords: keywords,
      types: types,
      stringPattern: #"(?:\"(?:[^\"\\]|\\.)*\"|`[^`]*`)"#,
      commentPatterns: [#"//.*$"#, #"/\*[\s\S]*?\*/"#],
      numberPattern: #"\b\d+\.?\d*\b"#
    )
  }

  private static func highlightRust(_ result: inout AttributedString, code: String) {
    let keywords = [
      "as",
      "async",
      "await",
      "break",
      "const",
      "continue",
      "else",
      "enum",
      "extern",
      "false",
      "fn",
      "for",
      "if",
      "impl",
      "in",
      "let",
      "loop",
      "match",
      "mod",
      "move",
      "mut",
      "pub",
      "ref",
      "return",
      "self",
      "Self",
      "static",
      "struct",
      "super",
      "trait",
      "true",
      "type",
      "unsafe",
      "use",
      "where",
      "while",
    ]
    let types = [
      "i8",
      "i16",
      "i32",
      "i64",
      "u8",
      "u16",
      "u32",
      "u64",
      "f32",
      "f64",
      "bool",
      "char",
      "str",
      "String",
      "Vec",
      "Option",
      "Result",
      "Box",
      "Some",
      "None",
      "Ok",
      "Err",
    ]

    applyPatterns(
      &result,
      code: code,
      keywords: keywords,
      types: types,
      stringPattern: #"\"(?:[^\"\\]|\\.)*\""#,
      commentPatterns: [#"//.*$"#, #"/\*[\s\S]*?\*/"#],
      numberPattern: #"\b\d+\.?\d*\b"#
    )
    applyPattern(&result, code: code, pattern: #"\b\w+!"#, color: Color.syntaxFunction)
  }

  private static func highlightHTML(_ result: inout AttributedString, code: String) {
    applyPattern(&result, code: code, pattern: #"</?[a-zA-Z][a-zA-Z0-9]*"#, color: Color.syntaxKeyword)
    applyPattern(&result, code: code, pattern: #"\b[a-zA-Z-]+(?==)"#, color: Color.syntaxProperty)
    applyPattern(&result, code: code, pattern: #"\"[^\"]*\""#, color: Color.syntaxString)
    applyPattern(&result, code: code, pattern: #"<!--[\s\S]*?-->"#, color: Color.syntaxComment)
  }

  private static func highlightCSS(_ result: inout AttributedString, code: String) {
    applyPattern(&result, code: code, pattern: #"[.#]?[a-zA-Z_-][a-zA-Z0-9_-]*(?=\s*\{)"#, color: Color.syntaxFunction)
    applyPattern(&result, code: code, pattern: #"[a-zA-Z-]+(?=\s*:)"#, color: Color.syntaxProperty)
    applyPattern(&result, code: code, pattern: #"\b\d+\.?\d*(px|em|rem|%|vh|vw)?\b"#, color: Color.syntaxNumber)
    applyPattern(&result, code: code, pattern: #"/\*[\s\S]*?\*/"#, color: Color.syntaxComment)
  }

  private static func highlightJSON(_ result: inout AttributedString, code: String) {
    applyPattern(&result, code: code, pattern: #"\"[^\"]+\"\s*(?=:)"#, color: Color.syntaxProperty)
    applyPattern(&result, code: code, pattern: #":\s*(\"[^\"]*\")"#, color: Color.syntaxString, group: 1)
    applyPattern(&result, code: code, pattern: #":\s*(-?\d+\.?\d*)"#, color: Color.syntaxNumber, group: 1)
    applyPattern(&result, code: code, pattern: #"\b(true|false|null)\b"#, color: Color.syntaxKeyword)
  }

  private static func highlightBash(_ result: inout AttributedString, code: String) {
    let keywords = [
      "if",
      "then",
      "else",
      "elif",
      "fi",
      "case",
      "esac",
      "for",
      "while",
      "until",
      "do",
      "done",
      "in",
      "function",
      "return",
      "exit",
      "break",
      "continue",
      "export",
      "local",
    ]
    for keyword in keywords {
      applyPattern(&result, code: code, pattern: "\\b\(keyword)\\b", color: Color.syntaxKeyword)
    }
    applyPattern(&result, code: code, pattern: #"#.*$"#, color: Color.syntaxComment)
    applyPattern(&result, code: code, pattern: #"(?:\"(?:[^\"\\]|\\.)*\"|'[^']*')"#, color: Color.syntaxString)
    applyPattern(&result, code: code, pattern: #"\$\{?\w+\}?"#, color: Color.syntaxProperty)
  }

  private static func highlightYAML(_ result: inout AttributedString, code: String) {
    applyPattern(&result, code: code, pattern: #"^[\s-]*[a-zA-Z_][a-zA-Z0-9_]*(?=\s*:)"#, color: Color.syntaxProperty)
    applyPattern(&result, code: code, pattern: #"(?:\"[^\"]*\"|'[^']*')"#, color: Color.syntaxString)
    applyPattern(
      &result,
      code: code,
      pattern: #"\b(true|false|yes|no|null|~)\b"#,
      color: Color.syntaxKeyword,
      caseInsensitive: true
    )
    applyPattern(&result, code: code, pattern: #"#.*$"#, color: Color.syntaxComment)
  }

  private static func highlightSQL(_ result: inout AttributedString, code: String) {
    let keywords = [
      "SELECT",
      "FROM",
      "WHERE",
      "AND",
      "OR",
      "JOIN",
      "LEFT",
      "RIGHT",
      "INNER",
      "ON",
      "GROUP",
      "BY",
      "ORDER",
      "ASC",
      "DESC",
      "LIMIT",
      "INSERT",
      "INTO",
      "VALUES",
      "UPDATE",
      "SET",
      "DELETE",
      "CREATE",
      "TABLE",
      "DROP",
      "ALTER",
    ]
    for keyword in keywords {
      applyPattern(&result, code: code, pattern: "\\b\(keyword)\\b", color: Color.syntaxKeyword, caseInsensitive: true)
    }
    applyPattern(&result, code: code, pattern: #"'[^']*'"#, color: Color.syntaxString)
    applyPattern(&result, code: code, pattern: #"--.*$"#, color: Color.syntaxComment)
  }

  private static func highlightGeneric(_ result: inout AttributedString, code: String) {
    applyPattern(
      &result,
      code: code,
      pattern: #"(?:\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*')"#,
      color: Color.syntaxString
    )
    applyPattern(&result, code: code, pattern: #"\b\d+\.?\d*\b"#, color: Color.syntaxNumber)
    applyPattern(&result, code: code, pattern: #"//.*$"#, color: Color.syntaxComment)
    applyPattern(&result, code: code, pattern: #"#.*$"#, color: Color.syntaxComment)
  }

  // MARK: - Helpers

  private static func applyLinePatterns(
    _ result: inout AttributedString,
    line: String,
    keywords: [String],
    types: [String],
    stringPattern: String,
    commentPattern: String,
    numberPattern: String
  ) {
    applyPattern(&result, code: line, pattern: commentPattern, color: Color.syntaxComment)
    applyPattern(&result, code: line, pattern: stringPattern, color: Color.syntaxString)
    for keyword in keywords {
      applyPattern(
        &result,
        code: line,
        pattern: "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b",
        color: Color.syntaxKeyword
      )
    }
    for type in types {
      applyPattern(
        &result,
        code: line,
        pattern: "\\b\(NSRegularExpression.escapedPattern(for: type))\\b",
        color: Color.syntaxType
      )
    }
    applyPattern(&result, code: line, pattern: numberPattern, color: Color.syntaxNumber)
  }

  private static func applyPatterns(
    _ result: inout AttributedString,
    code: String,
    keywords: [String],
    types: [String],
    stringPattern: String,
    commentPatterns: [String],
    numberPattern: String
  ) {
    for pattern in commentPatterns {
      applyPattern(&result, code: code, pattern: pattern, color: Color.syntaxComment)
    }
    applyPattern(&result, code: code, pattern: stringPattern, color: Color.syntaxString)
    for keyword in keywords {
      applyPattern(
        &result,
        code: code,
        pattern: "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b",
        color: Color.syntaxKeyword
      )
    }
    for type in types {
      applyPattern(
        &result,
        code: code,
        pattern: "\\b\(NSRegularExpression.escapedPattern(for: type))\\b",
        color: Color.syntaxType
      )
    }
    applyPattern(&result, code: code, pattern: numberPattern, color: Color.syntaxNumber)
  }

  private static func applyPattern(
    _ result: inout AttributedString,
    code: String,
    pattern: String,
    color: Color,
    group: Int = 0,
    caseInsensitive: Bool = false
  ) {
    var options: NSRegularExpression.Options = [.anchorsMatchLines]
    if caseInsensitive { options.insert(.caseInsensitive) }

    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }

    let nsString = code as NSString
    let matches = regex.matches(in: code, range: NSRange(location: 0, length: nsString.length))

    for match in matches {
      let range = group > 0 && match.numberOfRanges > group ? match.range(at: group) : match.range
      guard range.location != NSNotFound else { continue }

      if let swiftRange = Range(range, in: code),
         let attrRange = Range(swiftRange, in: result)
      {
        result[attrRange].foregroundColor = color
      }
    }
  }
}
