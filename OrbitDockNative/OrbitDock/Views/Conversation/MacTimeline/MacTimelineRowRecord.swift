import Foundation

#if os(macOS)

  enum MacTimelineRowRecord: Equatable, Identifiable {
    case utility(MacTimelineUtilityRecord)
    case message(MacTimelineMessageRecord)
    case tool(MacTimelineToolRecord)
    case expandedTool(MacTimelineExpandedToolRecord)
    case loadMore(MacTimelineLoadMoreRecord)
    case spacer(MacTimelineSpacerRecord)

    var id: String {
      switch self {
        case .utility(let record):
          return record.id
        case .message(let record):
          return record.id
        case .tool(let record):
          return record.id
        case .expandedTool(let record):
          return record.id
        case .loadMore(let record):
          return record.id
        case .spacer(let record):
          return record.id
      }
    }
  }

  struct MacTimelineUtilityRecord: Equatable, Identifiable {
    enum Kind: Equatable {
      case approval
      case live
      case workers
      case activity
    }

    struct Chip: Equatable, Identifiable {
      let id: String
      let title: String
      let statusText: String
      let accentColorName: String
      let isActive: Bool
    }

    let id: String
    let kind: Kind
    let iconName: String
    let eyebrow: String?
    let title: String
    let subtitle: String?
    let spotlight: String?
    let trailingBadge: String?
    let accentColorName: String
    let chips: [Chip]
    let activityAnchorID: String?
    let isExpanded: Bool
  }

  struct MacTimelineMessageRecord: Equatable, Identifiable {
    let id: String
    let model: NativeRichMessageRowModel
    let contentSignature: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.id == rhs.id
        && lhs.contentSignature == rhs.contentSignature
        && lhs.model.speaker == rhs.model.speaker
        && lhs.model.content == rhs.model.content
        && lhs.model.messageType == rhs.model.messageType
        && lhs.model.renderMode == rhs.model.renderMode
        && lhs.model.showHeader == rhs.model.showHeader
        && lhs.model.isThinkingExpanded == rhs.model.isThinkingExpanded
        && lhs.model.images.count == rhs.model.images.count
    }
  }

  struct MacTimelineToolRecord: Identifiable, Equatable {
    let id: String
    let model: NativeCompactToolRowModel

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.id == rhs.id
        && lhs.model.glyphSymbol == rhs.model.glyphSymbol
        && lhs.model.summary == rhs.model.summary
        && lhs.model.subtitle == rhs.model.subtitle
        && lhs.model.rightMeta == rhs.model.rightMeta
        && lhs.model.linkedWorkerID == rhs.model.linkedWorkerID
        && lhs.model.linkedWorkerLabel == rhs.model.linkedWorkerLabel
        && lhs.model.linkedWorkerStatusText == rhs.model.linkedWorkerStatusText
        && lhs.model.isFocusedWorker == rhs.model.isFocusedWorker
        && lhs.model.isInProgress == rhs.model.isInProgress
        && lhs.model.liveOutputPreview == rhs.model.liveOutputPreview
        && lhs.model.outputPreview == rhs.model.outputPreview
    }
  }

  struct MacTimelineExpandedToolRecord: Identifiable, Equatable {
    let id: String
    let model: NativeExpandedToolModel

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.id == rhs.id
        && lhs.model.messageID == rhs.model.messageID
        && lhs.model.iconName == rhs.model.iconName
        && lhs.model.hasError == rhs.model.hasError
        && lhs.model.isInProgress == rhs.model.isInProgress
        && lhs.model.canCancel == rhs.model.canCancel
        && lhs.model.duration == rhs.model.duration
        && lhs.model.linkedWorkerID == rhs.model.linkedWorkerID
        && contentSignature(lhs.model.content) == contentSignature(rhs.model.content)
    }

    private static func contentSignature(_ content: NativeToolContent) -> Int {
      var hasher = Hasher()
      switch content {
        case let .bash(command, input, output):
          hasher.combine("bash")
          hasher.combine(command)
          hasher.combine(input)
          hasher.combine(output)
        case let .edit(filename, path, additions, deletions, lines, isWriteNew):
          hasher.combine("edit")
          hasher.combine(filename)
          hasher.combine(path)
          hasher.combine(additions)
          hasher.combine(deletions)
          hasher.combine(lines.count)
          hasher.combine(isWriteNew)
        case let .read(filename, path, language, lines):
          hasher.combine("read")
          hasher.combine(filename)
          hasher.combine(path)
          hasher.combine(language)
          hasher.combine(lines.count)
        case let .glob(pattern, grouped):
          hasher.combine("glob")
          hasher.combine(pattern)
          hasher.combine(grouped.count)
        case let .grep(pattern, grouped):
          hasher.combine("grep")
          hasher.combine(pattern)
          hasher.combine(grouped.count)
        case let .task(agentLabel, _, description, output, isComplete):
          hasher.combine("task")
          hasher.combine(agentLabel)
          hasher.combine(description)
          hasher.combine(output)
          hasher.combine(isComplete)
        case let .todo(title, subtitle, items, output):
          hasher.combine("todo")
          hasher.combine(title)
          hasher.combine(subtitle)
          hasher.combine(items.count)
          hasher.combine(output)
        case let .mcp(server, displayTool, subtitle, input, output):
          hasher.combine("mcp")
          hasher.combine(server)
          hasher.combine(displayTool)
          hasher.combine(subtitle)
          hasher.combine(input)
          hasher.combine(output)
        case let .webFetch(domain, url, input, output):
          hasher.combine("webFetch")
          hasher.combine(domain)
          hasher.combine(url)
          hasher.combine(input)
          hasher.combine(output)
        case let .webSearch(query, input, output):
          hasher.combine("webSearch")
          hasher.combine(query)
          hasher.combine(input)
          hasher.combine(output)
        case let .generic(toolName, input, output):
          hasher.combine("generic")
          hasher.combine(toolName)
          hasher.combine(input)
          hasher.combine(output)
      }
      return hasher.finalize()
    }
  }

  struct MacTimelineLoadMoreRecord: Equatable, Identifiable {
    let id: String
    let remainingCount: Int
  }

  struct MacTimelineSpacerRecord: Equatable, Identifiable {
    let id: String
    let height: CGFloat
  }

#endif
