//
//  MarkdownView.swift
//  CommandCenter
//
//  Markdown rendering using MarkdownUI library

import SwiftUI
import AppKit
import MarkdownUI

// MARK: - Main Markdown View

struct MarkdownContentView: View {
    let content: String

    var body: some View {
        Markdown(content)
            .markdownTheme(.commandCenter)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                NSWorkspace.shared.open(url)
                return .handled
            })
    }
}

// Alias for backwards compatibility
typealias MarkdownView = MarkdownContentView

// MARK: - Custom Theme

extension MarkdownUI.Theme {
    static let commandCenter = Theme()
        .text {
            ForegroundColor(.primary)
            FontSize(12)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(11)
            ForegroundColor(Color(red: 0.90, green: 0.60, blue: 0.45))
            BackgroundColor(Color.white.opacity(0.06))
        }
        .strong {
            FontWeight(.semibold)
        }
        .emphasis {
            FontStyle(.italic)
        }
        .link {
            ForegroundColor(Color(red: 0.45, green: 0.68, blue: 0.90))
            UnderlineStyle(.single)
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(20)
                    FontWeight(.bold)
                    ForegroundColor(.primary)
                }
                .markdownMargin(top: 16, bottom: 8)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(17)
                    FontWeight(.semibold)
                    ForegroundColor(.primary)
                }
                .markdownMargin(top: 14, bottom: 6)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(14)
                    FontWeight(.semibold)
                    ForegroundColor(.primary)
                }
                .markdownMargin(top: 12, bottom: 4)
        }
        .paragraph { configuration in
            configuration.label
                .markdownMargin(top: 0, bottom: 8)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 2, bottom: 2)
        }
        .taskListMarker { configuration in
            TaskListCheckbox(isCompleted: configuration.isCompleted)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.purple.opacity(0.6))
                    .frame(width: 3)
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(.secondary)
                        FontStyle(.italic)
                    }
                    .padding(.leading, 12)
            }
            .markdownMargin(top: 8, bottom: 8)
        }
        .thematicBreak {
            HorizontalDivider()
                .markdownMargin(top: 16, bottom: 16)
        }
        .codeBlock { configuration in
            CodeBlockView(
                language: configuration.language,
                code: configuration.content
            )
            .markdownMargin(top: 8, bottom: 8)
        }
        .table { configuration in
            configuration.label
                .markdownTableBackgroundStyle(.alternatingRows(Color.white.opacity(0.02), Color.white.opacity(0.05)))
                .markdownTableBorderStyle(.init(color: Color.white.opacity(0.1)))
                .markdownMargin(top: 8, bottom: 8)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(11)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
        }
}

// MARK: - Task List Checkbox

struct TaskListCheckbox: View {
    let isCompleted: Bool

    var body: some View {
        Image(systemName: isCompleted ? "checkmark.square.fill" : "square")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isCompleted ? Color.green : Color.secondary)
            .frame(width: 18)
    }
}

// MARK: - Horizontal Divider

struct HorizontalDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 4, height: 4)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Code Block View

struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var isHovering = false
    @State private var copied = false
    @State private var isExpanded = false

    private let collapseThreshold = 15  // Lines before collapsing
    private let collapsedLineCount = 8  // Lines to show when collapsed

    private var lines: [String] {
        code.components(separatedBy: "\n")
    }

    private var shouldCollapse: Bool {
        lines.count > collapseThreshold
    }

    private var displayedCode: String {
        if shouldCollapse && !isExpanded {
            return lines.prefix(collapsedLineCount).joined(separator: "\n")
        }
        return code
    }

    private var normalizedLanguage: String? {
        guard let lang = language?.lowercased() else { return nil }
        switch lang {
        case "js": return "javascript"
        case "ts": return "typescript"
        case "tsx": return "typescript"
        case "jsx": return "javascript"
        case "sh", "shell", "zsh": return "bash"
        case "py": return "python"
        case "rb": return "ruby"
        case "yml": return "yaml"
        case "md": return "markdown"
        case "objective-c", "objc": return "objectivec"
        default: return lang
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header

            Divider()
                .opacity(0.3)

            // Code content with line numbers
            codeContent

            // Expand/collapse button for long code
            if shouldCollapse {
                expandCollapseButton
            }
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .onHover { isHovering = $0 }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 8) {
            if let lang = normalizedLanguage ?? language, !lang.isEmpty {
                HStack(spacing: 4) {
                    Circle()
                        .fill(languageColor(lang))
                        .frame(width: 8, height: 8)
                    Text(lang)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Line count
            Text("\(lines.count) lines")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            // Copy button
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                copied = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                    if copied {
                        Text("Copied")
                            .font(.system(size: 9, weight: .medium))
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                .foregroundStyle(copied ? .green : .secondary)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: copied)
            }
            .buttonStyle(.plain)
            .opacity(isHovering || copied ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .onChange(of: isHovering) { _, newValue in
                if !newValue { copied = false }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var codeContent: some View {
        let displayLines = displayedCode.components(separatedBy: "\n")
        let maxLineNumWidth = "\(lines.count)".count

        return ScrollView([.horizontal], showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                // Line numbers
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(Array(displayLines.enumerated()), id: \.offset) { index, _ in
                        Text("\(index + 1)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: CGFloat(maxLineNumWidth) * 8 + 8, alignment: .trailing)
                            .frame(height: 16)
                    }
                }
                .padding(.trailing, 12)
                .padding(.leading, 8)
                .background(Color.white.opacity(0.02))

                // Highlighted code
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(displayLines.enumerated()), id: \.offset) { index, line in
                        Text(SyntaxHighlighter.highlightLine(line, language: normalizedLanguage))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 16, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 8)
        }
        .frame(maxHeight: shouldCollapse && !isExpanded ? CGFloat(collapsedLineCount) * 16 + 20 : min(CGFloat(lines.count) * 16 + 20, 500))
    }

    private var expandCollapseButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                Text(isExpanded ? "Show less" : "Show \(lines.count - collapsedLineCount) more lines")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.03))
        }
        .buttonStyle(.plain)
    }

    private func languageColor(_ lang: String) -> Color {
        switch lang.lowercased() {
        case "swift": return .orange
        case "javascript", "typescript": return .yellow
        case "python": return .blue
        case "ruby": return .red
        case "go": return .cyan
        case "rust": return .orange
        case "bash": return .green
        case "json": return .purple
        case "html": return .red
        case "css": return .blue
        case "sql": return .cyan
        default: return .secondary
        }
    }
}

// MARK: - Syntax Highlighter

enum SyntaxColors {
    static let keyword = Color(red: 0.78, green: 0.46, blue: 0.82)
    static let string = Color(red: 0.81, green: 0.54, blue: 0.40)
    static let number = Color(red: 0.71, green: 0.81, blue: 0.54)
    static let comment = Color(red: 0.42, green: 0.47, blue: 0.42)
    static let type = Color(red: 0.31, green: 0.73, blue: 0.78)
    static let function = Color(red: 0.87, green: 0.87, blue: 0.67)
    static let property = Color(red: 0.61, green: 0.78, blue: 0.92)
    static let text = Color(red: 0.85, green: 0.85, blue: 0.85)
}

struct SyntaxHighlighter {
    // Highlight a single line (for line-by-line rendering)
    static func highlightLine(_ line: String, language: String?) -> AttributedString {
        var result = AttributedString(line)
        result.foregroundColor = SyntaxColors.text

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

    // Full code highlighting (for backwards compat)
    static func highlight(_ code: String, language: String?) -> AttributedString {
        var result = AttributedString(code)
        result.foregroundColor = SyntaxColors.text

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
        let keywords = ["func", "let", "var", "if", "else", "guard", "return", "import", "struct", "class", "enum", "protocol", "extension", "private", "public", "internal", "static", "override", "final", "lazy", "weak", "mutating", "throws", "try", "catch", "async", "await", "some", "any", "self", "Self", "nil", "true", "false", "in", "for", "while", "switch", "case", "default", "break", "continue", "defer", "do", "init", "deinit", "is", "as"]
        let types = ["String", "Int", "Double", "Float", "Bool", "Array", "Dictionary", "Set", "Optional", "View", "Any", "Void", "Date", "Data", "URL"]

        applyLinePatterns(&result, line: line, keywords: keywords, types: types,
            stringPattern: #"\"(?:[^\"\\]|\\.)*\""#,
            commentPattern: #"//.*$"#,
            numberPattern: #"\b\d+\.?\d*\b"#)
        applyPattern(&result, code: line, pattern: #"@\w+"#, color: SyntaxColors.keyword)
    }

    private static func highlightJavaScriptLine(_ result: inout AttributedString, line: String) {
        let keywords = ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "throw", "try", "catch", "finally", "new", "typeof", "instanceof", "this", "class", "extends", "static", "async", "await", "import", "export", "from", "as", "true", "false", "null", "undefined"]
        let types = ["Array", "Object", "String", "Number", "Boolean", "Promise", "Map", "Set", "Date", "Error", "JSON", "console"]

        applyLinePatterns(&result, line: line, keywords: keywords, types: types,
            stringPattern: #"(?:\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`)"#,
            commentPattern: #"//.*$"#,
            numberPattern: #"\b\d+\.?\d*\b"#)
        applyPattern(&result, code: line, pattern: #"=>"#, color: SyntaxColors.keyword)
    }

    private static func highlightPythonLine(_ result: inout AttributedString, line: String) {
        let keywords = ["def", "class", "if", "elif", "else", "for", "while", "try", "except", "finally", "with", "as", "import", "from", "return", "yield", "raise", "pass", "break", "continue", "lambda", "and", "or", "not", "in", "is", "True", "False", "None", "self", "async", "await", "global"]
        let types = ["int", "str", "float", "bool", "list", "dict", "set", "tuple", "print", "range", "len", "open"]

        applyLinePatterns(&result, line: line, keywords: keywords, types: types,
            stringPattern: #"(?:\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*')"#,
            commentPattern: #"#.*$"#,
            numberPattern: #"\b\d+\.?\d*\b"#)
        applyPattern(&result, code: line, pattern: #"@\w+"#, color: SyntaxColors.function)
    }

    private static func highlightGoLine(_ result: inout AttributedString, line: String) {
        let keywords = ["break", "case", "chan", "const", "continue", "default", "defer", "else", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var", "true", "false", "nil"]
        let types = ["bool", "byte", "error", "float32", "float64", "int", "int8", "int16", "int32", "int64", "rune", "string", "uint", "make", "new", "append", "len", "panic", "print"]

        applyLinePatterns(&result, line: line, keywords: keywords, types: types,
            stringPattern: #"(?:\"(?:[^\"\\]|\\.)*\"|`[^`]*`)"#,
            commentPattern: #"//.*$"#,
            numberPattern: #"\b\d+\.?\d*\b"#)
    }

    private static func highlightRustLine(_ result: inout AttributedString, line: String) {
        let keywords = ["as", "async", "await", "break", "const", "continue", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"]
        let types = ["i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64", "bool", "char", "str", "String", "Vec", "Option", "Result", "Box", "Some", "None", "Ok", "Err"]

        applyLinePatterns(&result, line: line, keywords: keywords, types: types,
            stringPattern: #"\"(?:[^\"\\]|\\.)*\""#,
            commentPattern: #"//.*$"#,
            numberPattern: #"\b\d+\.?\d*\b"#)
        applyPattern(&result, code: line, pattern: #"\b\w+!"#, color: SyntaxColors.function)
    }

    private static func highlightHTMLLine(_ result: inout AttributedString, line: String) {
        applyPattern(&result, code: line, pattern: #"</?[a-zA-Z][a-zA-Z0-9]*"#, color: SyntaxColors.keyword)
        applyPattern(&result, code: line, pattern: #"\b[a-zA-Z-]+(?==)"#, color: SyntaxColors.property)
        applyPattern(&result, code: line, pattern: #"\"[^\"]*\""#, color: SyntaxColors.string)
        applyPattern(&result, code: line, pattern: #"<!--.*-->"#, color: SyntaxColors.comment)
    }

    private static func highlightCSSLine(_ result: inout AttributedString, line: String) {
        applyPattern(&result, code: line, pattern: #"[.#]?[a-zA-Z_-][a-zA-Z0-9_-]*(?=\s*\{)"#, color: SyntaxColors.function)
        applyPattern(&result, code: line, pattern: #"[a-zA-Z-]+(?=\s*:)"#, color: SyntaxColors.property)
        applyPattern(&result, code: line, pattern: #"\b\d+\.?\d*(px|em|rem|%|vh|vw)?\b"#, color: SyntaxColors.number)
        applyPattern(&result, code: line, pattern: #"/\*.*\*/"#, color: SyntaxColors.comment)
    }

    private static func highlightJSONLine(_ result: inout AttributedString, line: String) {
        applyPattern(&result, code: line, pattern: #"\"[^\"]+\"\s*(?=:)"#, color: SyntaxColors.property)
        applyPattern(&result, code: line, pattern: #":\s*(\"[^\"]*\")"#, color: SyntaxColors.string, group: 1)
        applyPattern(&result, code: line, pattern: #":\s*(-?\d+\.?\d*)"#, color: SyntaxColors.number, group: 1)
        applyPattern(&result, code: line, pattern: #"\b(true|false|null)\b"#, color: SyntaxColors.keyword)
    }

    private static func highlightBashLine(_ result: inout AttributedString, line: String) {
        let keywords = ["if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done", "in", "function", "return", "exit", "break", "continue", "export", "local"]
        for keyword in keywords {
            applyPattern(&result, code: line, pattern: "\\b\(keyword)\\b", color: SyntaxColors.keyword)
        }
        applyPattern(&result, code: line, pattern: #"#.*$"#, color: SyntaxColors.comment)
        applyPattern(&result, code: line, pattern: #"(?:\"(?:[^\"\\]|\\.)*\"|'[^']*')"#, color: SyntaxColors.string)
        applyPattern(&result, code: line, pattern: #"\$\{?\w+\}?"#, color: SyntaxColors.property)
    }

    private static func highlightYAMLLine(_ result: inout AttributedString, line: String) {
        applyPattern(&result, code: line, pattern: #"^[\s-]*[a-zA-Z_][a-zA-Z0-9_]*(?=\s*:)"#, color: SyntaxColors.property)
        applyPattern(&result, code: line, pattern: #"(?:\"[^\"]*\"|'[^']*')"#, color: SyntaxColors.string)
        applyPattern(&result, code: line, pattern: #"\b(true|false|yes|no|null|~)\b"#, color: SyntaxColors.keyword, caseInsensitive: true)
        applyPattern(&result, code: line, pattern: #"#.*$"#, color: SyntaxColors.comment)
    }

    private static func highlightSQLLine(_ result: inout AttributedString, line: String) {
        let keywords = ["SELECT", "FROM", "WHERE", "AND", "OR", "JOIN", "LEFT", "RIGHT", "INNER", "ON", "GROUP", "BY", "ORDER", "ASC", "DESC", "LIMIT", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "DROP", "ALTER"]
        for keyword in keywords {
            applyPattern(&result, code: line, pattern: "\\b\(keyword)\\b", color: SyntaxColors.keyword, caseInsensitive: true)
        }
        applyPattern(&result, code: line, pattern: #"'[^']*'"#, color: SyntaxColors.string)
        applyPattern(&result, code: line, pattern: #"--.*$"#, color: SyntaxColors.comment)
    }

    private static func highlightGenericLine(_ result: inout AttributedString, line: String) {
        applyPattern(&result, code: line, pattern: #"(?:\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*')"#, color: SyntaxColors.string)
        applyPattern(&result, code: line, pattern: #"\b\d+\.?\d*\b"#, color: SyntaxColors.number)
        applyPattern(&result, code: line, pattern: #"//.*$"#, color: SyntaxColors.comment)
        applyPattern(&result, code: line, pattern: #"#.*$"#, color: SyntaxColors.comment)
    }

    // MARK: - Full code highlighters (for backwards compat)

    private static func highlightSwift(_ result: inout AttributedString, code: String) {
        let keywords = ["func", "let", "var", "if", "else", "guard", "return", "import", "struct", "class", "enum", "protocol", "extension", "private", "public", "internal", "static", "override", "final", "lazy", "weak", "mutating", "throws", "try", "catch", "async", "await", "some", "any", "self", "Self", "nil", "true", "false", "in", "for", "while", "switch", "case", "default", "break", "continue", "defer", "do", "init", "deinit", "is", "as", "@State", "@Binding", "@Published", "@ObservedObject", "@StateObject", "@Environment", "@MainActor"]
        let types = ["String", "Int", "Double", "Float", "Bool", "Array", "Dictionary", "Set", "Optional", "View", "Any", "Void", "Date", "Data", "URL"]

        applyPatterns(&result, code: code, keywords: keywords, types: types,
            stringPattern: #"\"(?:[^\"\\]|\\.)*\""#,
            commentPatterns: [#"//.*$"#, #"/\*[\s\S]*?\*/"#],
            numberPattern: #"\b\d+\.?\d*\b"#)
        applyPattern(&result, code: code, pattern: #"@\w+"#, color: SyntaxColors.keyword)
    }

    private static func highlightJavaScript(_ result: inout AttributedString, code: String) {
        let keywords = ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "throw", "try", "catch", "finally", "new", "typeof", "instanceof", "this", "class", "extends", "static", "async", "await", "import", "export", "from", "as", "true", "false", "null", "undefined"]
        let types = ["Array", "Object", "String", "Number", "Boolean", "Promise", "Map", "Set", "Date", "Error", "JSON", "console"]

        applyPatterns(&result, code: code, keywords: keywords, types: types,
            stringPattern: #"(?:\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`)"#,
            commentPatterns: [#"//.*$"#, #"/\*[\s\S]*?\*/"#],
            numberPattern: #"\b\d+\.?\d*\b"#)
        applyPattern(&result, code: code, pattern: #"=>"#, color: SyntaxColors.keyword)
    }

    private static func highlightPython(_ result: inout AttributedString, code: String) {
        let keywords = ["def", "class", "if", "elif", "else", "for", "while", "try", "except", "finally", "with", "as", "import", "from", "return", "yield", "raise", "pass", "break", "continue", "lambda", "and", "or", "not", "in", "is", "True", "False", "None", "self", "async", "await", "global"]
        let types = ["int", "str", "float", "bool", "list", "dict", "set", "tuple", "print", "range", "len", "open"]

        applyPatterns(&result, code: code, keywords: keywords, types: types,
            stringPattern: #"(?:\"\"\"[\s\S]*?\"\"\"|'''[\s\S]*?'''|\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*')"#,
            commentPatterns: [#"#.*$"#],
            numberPattern: #"\b\d+\.?\d*\b"#)
        applyPattern(&result, code: code, pattern: #"@\w+"#, color: SyntaxColors.function)
    }

    private static func highlightGo(_ result: inout AttributedString, code: String) {
        let keywords = ["break", "case", "chan", "const", "continue", "default", "defer", "else", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var", "true", "false", "nil"]
        let types = ["bool", "byte", "error", "float32", "float64", "int", "int8", "int16", "int32", "int64", "rune", "string", "uint", "make", "new", "append", "len", "panic", "print"]

        applyPatterns(&result, code: code, keywords: keywords, types: types,
            stringPattern: #"(?:\"(?:[^\"\\]|\\.)*\"|`[^`]*`)"#,
            commentPatterns: [#"//.*$"#, #"/\*[\s\S]*?\*/"#],
            numberPattern: #"\b\d+\.?\d*\b"#)
    }

    private static func highlightRust(_ result: inout AttributedString, code: String) {
        let keywords = ["as", "async", "await", "break", "const", "continue", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"]
        let types = ["i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64", "bool", "char", "str", "String", "Vec", "Option", "Result", "Box", "Some", "None", "Ok", "Err"]

        applyPatterns(&result, code: code, keywords: keywords, types: types,
            stringPattern: #"\"(?:[^\"\\]|\\.)*\""#,
            commentPatterns: [#"//.*$"#, #"/\*[\s\S]*?\*/"#],
            numberPattern: #"\b\d+\.?\d*\b"#)
        applyPattern(&result, code: code, pattern: #"\b\w+!"#, color: SyntaxColors.function)
    }

    private static func highlightHTML(_ result: inout AttributedString, code: String) {
        applyPattern(&result, code: code, pattern: #"</?[a-zA-Z][a-zA-Z0-9]*"#, color: SyntaxColors.keyword)
        applyPattern(&result, code: code, pattern: #"\b[a-zA-Z-]+(?==)"#, color: SyntaxColors.property)
        applyPattern(&result, code: code, pattern: #"\"[^\"]*\""#, color: SyntaxColors.string)
        applyPattern(&result, code: code, pattern: #"<!--[\s\S]*?-->"#, color: SyntaxColors.comment)
    }

    private static func highlightCSS(_ result: inout AttributedString, code: String) {
        applyPattern(&result, code: code, pattern: #"[.#]?[a-zA-Z_-][a-zA-Z0-9_-]*(?=\s*\{)"#, color: SyntaxColors.function)
        applyPattern(&result, code: code, pattern: #"[a-zA-Z-]+(?=\s*:)"#, color: SyntaxColors.property)
        applyPattern(&result, code: code, pattern: #"\b\d+\.?\d*(px|em|rem|%|vh|vw)?\b"#, color: SyntaxColors.number)
        applyPattern(&result, code: code, pattern: #"/\*[\s\S]*?\*/"#, color: SyntaxColors.comment)
    }

    private static func highlightJSON(_ result: inout AttributedString, code: String) {
        applyPattern(&result, code: code, pattern: #"\"[^\"]+\"\s*(?=:)"#, color: SyntaxColors.property)
        applyPattern(&result, code: code, pattern: #":\s*(\"[^\"]*\")"#, color: SyntaxColors.string, group: 1)
        applyPattern(&result, code: code, pattern: #":\s*(-?\d+\.?\d*)"#, color: SyntaxColors.number, group: 1)
        applyPattern(&result, code: code, pattern: #"\b(true|false|null)\b"#, color: SyntaxColors.keyword)
    }

    private static func highlightBash(_ result: inout AttributedString, code: String) {
        let keywords = ["if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done", "in", "function", "return", "exit", "break", "continue", "export", "local"]
        for keyword in keywords {
            applyPattern(&result, code: code, pattern: "\\b\(keyword)\\b", color: SyntaxColors.keyword)
        }
        applyPattern(&result, code: code, pattern: #"#.*$"#, color: SyntaxColors.comment)
        applyPattern(&result, code: code, pattern: #"(?:\"(?:[^\"\\]|\\.)*\"|'[^']*')"#, color: SyntaxColors.string)
        applyPattern(&result, code: code, pattern: #"\$\{?\w+\}?"#, color: SyntaxColors.property)
    }

    private static func highlightYAML(_ result: inout AttributedString, code: String) {
        applyPattern(&result, code: code, pattern: #"^[\s-]*[a-zA-Z_][a-zA-Z0-9_]*(?=\s*:)"#, color: SyntaxColors.property)
        applyPattern(&result, code: code, pattern: #"(?:\"[^\"]*\"|'[^']*')"#, color: SyntaxColors.string)
        applyPattern(&result, code: code, pattern: #"\b(true|false|yes|no|null|~)\b"#, color: SyntaxColors.keyword, caseInsensitive: true)
        applyPattern(&result, code: code, pattern: #"#.*$"#, color: SyntaxColors.comment)
    }

    private static func highlightSQL(_ result: inout AttributedString, code: String) {
        let keywords = ["SELECT", "FROM", "WHERE", "AND", "OR", "JOIN", "LEFT", "RIGHT", "INNER", "ON", "GROUP", "BY", "ORDER", "ASC", "DESC", "LIMIT", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "DROP", "ALTER"]
        for keyword in keywords {
            applyPattern(&result, code: code, pattern: "\\b\(keyword)\\b", color: SyntaxColors.keyword, caseInsensitive: true)
        }
        applyPattern(&result, code: code, pattern: #"'[^']*'"#, color: SyntaxColors.string)
        applyPattern(&result, code: code, pattern: #"--.*$"#, color: SyntaxColors.comment)
    }

    private static func highlightGeneric(_ result: inout AttributedString, code: String) {
        applyPattern(&result, code: code, pattern: #"(?:\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*')"#, color: SyntaxColors.string)
        applyPattern(&result, code: code, pattern: #"\b\d+\.?\d*\b"#, color: SyntaxColors.number)
        applyPattern(&result, code: code, pattern: #"//.*$"#, color: SyntaxColors.comment)
        applyPattern(&result, code: code, pattern: #"#.*$"#, color: SyntaxColors.comment)
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
        applyPattern(&result, code: line, pattern: commentPattern, color: SyntaxColors.comment)
        applyPattern(&result, code: line, pattern: stringPattern, color: SyntaxColors.string)
        for keyword in keywords {
            applyPattern(&result, code: line, pattern: "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b", color: SyntaxColors.keyword)
        }
        for type in types {
            applyPattern(&result, code: line, pattern: "\\b\(NSRegularExpression.escapedPattern(for: type))\\b", color: SyntaxColors.type)
        }
        applyPattern(&result, code: line, pattern: numberPattern, color: SyntaxColors.number)
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
            applyPattern(&result, code: code, pattern: pattern, color: SyntaxColors.comment)
        }
        applyPattern(&result, code: code, pattern: stringPattern, color: SyntaxColors.string)
        for keyword in keywords {
            applyPattern(&result, code: code, pattern: "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b", color: SyntaxColors.keyword)
        }
        for type in types {
            applyPattern(&result, code: code, pattern: "\\b\(NSRegularExpression.escapedPattern(for: type))\\b", color: SyntaxColors.type)
        }
        applyPattern(&result, code: code, pattern: numberPattern, color: SyntaxColors.number)
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
               let attrRange = Range(swiftRange, in: result) {
                result[attrRange].foregroundColor = color
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            MarkdownContentView(content: """
            ## Markdown Rendering

            Here's a **bold statement** and some *italic text*.

            Check out this `inline code` example and a [link](https://example.com).

            ---

            ### Task List

            - [x] Completed task
            - [ ] Incomplete task
            - [x] Another done item

            | Language | Highlights |
            |----------|-----------|
            | Swift | Keywords, types |
            | JavaScript | ES6+, async/await |

            ```swift
            import SwiftUI

            struct ContentView: View {
                @State private var count = 0
                @State private var name = "World"

                var body: some View {
                    VStack(spacing: 20) {
                        Text("Hello, \\(name)!")
                            .font(.largeTitle)

                        Button("Count: \\(count)") {
                            count += 1
                        }

                        // This is a comment
                        ForEach(0..<5) { index in
                            Text("Item \\(index)")
                        }
                    }
                    .padding()
                }
            }
            ```

            > This is a blockquote with some important information.

            - List item one
            - List item two
            - List item three
            """)
        }
        .padding()
    }
    .frame(width: 600, height: 900)
    .background(Color(red: 0.11, green: 0.11, blue: 0.12))
}
