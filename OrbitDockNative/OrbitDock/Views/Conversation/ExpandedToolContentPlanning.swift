import Foundation

struct ExpandedToolContentPlan {
  let sections: [ExpandedToolContentSectionPlan]
}

enum ExpandedToolContentSectionPlan {
  case textOutput(lines: [String])
  case edit(ExpandedToolEditSectionPlan)
  case read(ExpandedToolReadSectionPlan)
  case glob(groups: [ExpandedToolGlobDirectoryPlan])
  case grep(groups: [ExpandedToolGrepMatchPlan])
  case todo(ExpandedToolTodoSectionPlan)
  case payload(ExpandedToolPayloadSectionRenderPlan)
}

struct ExpandedToolEditSectionPlan {
  let lines: [DiffLine]
  let isWriteNew: Bool
}

struct ExpandedToolReadSectionPlan {
  let language: String
  let lines: [String]
}

struct ExpandedToolGlobDirectoryPlan {
  let directory: String
  let displayName: String
  let files: [String]
}

struct ExpandedToolGrepMatchPlan {
  let file: String
  let displayName: String
  let matches: [String]
}

struct ExpandedToolTodoSectionPlan {
  let items: [NativeTodoItem]
  let outputLines: [String]
}

enum ExpandedToolContentPlanning {
  static func contentPlan(for model: NativeExpandedToolModel) -> ExpandedToolContentPlan {
    ExpandedToolContentPlan(sections: sections(for: model))
  }

  private static func sections(for model: NativeExpandedToolModel) -> [ExpandedToolContentSectionPlan] {
    switch model.content {
      case let .bash(_, input, output):
        payloadSections(toolName: nil, input: input, output: output)

      case let .edit(_, _, _, _, lines, isWriteNew):
        [.edit(ExpandedToolEditSectionPlan(lines: lines, isWriteNew: isWriteNew))]

      case let .read(_, _, language, lines):
        [.read(ExpandedToolReadSectionPlan(language: language, lines: lines))]

      case let .glob(_, grouped):
        [
          .glob(groups: grouped.map {
            ExpandedToolGlobDirectoryPlan(
              directory: $0.dir,
              displayName: "\($0.dir == "." ? "(root)" : $0.dir) (\($0.files.count))",
              files: $0.files.map { $0.components(separatedBy: "/").last ?? $0 }
            )
          })
        ]

      case let .grep(_, grouped):
        [
          .grep(groups: grouped.map {
            ExpandedToolGrepMatchPlan(
              file: $0.file,
              displayName: $0.file.components(separatedBy: "/").suffix(3).joined(separator: "/")
                + ($0.matches.isEmpty ? "" : " (\($0.matches.count))"),
              matches: $0.matches
            )
          })
        ]

      case let .task(_, _, _, output, _):
        [.textOutput(lines: displayLines(output))]

      case let .todo(_, _, items, output):
        [.todo(ExpandedToolTodoSectionPlan(items: items, outputLines: displayLines(output)))]

      case let .mcp(_, _, _, input, output):
        payloadSections(toolName: nil, input: input, output: output)

      case let .webFetch(_, _, input, output):
        payloadSections(toolName: nil, input: input, output: output)

      case let .webSearch(_, input, output):
        payloadSections(toolName: nil, input: input, output: output)

      case let .generic(toolName, input, output):
        payloadSections(toolName: toolName, input: input, output: output)
    }
  }

  private static func payloadSections(toolName: String?, input: String?, output: String?) -> [ExpandedToolContentSectionPlan] {
    [
      ExpandedToolRenderPlanning.payloadSectionRenderPlan(title: "INPUT", payload: input, toolName: toolName),
      ExpandedToolRenderPlanning.payloadSectionRenderPlan(title: "OUTPUT", payload: output)
    ]
    .compactMap { $0 }
    .map(ExpandedToolContentSectionPlan.payload)
  }

  private static func displayLines(_ text: String?) -> [String] {
    guard let text, !text.isEmpty else { return [] }
    return text.components(separatedBy: "\n").map { $0.isEmpty ? " " : $0 }
  }
}
