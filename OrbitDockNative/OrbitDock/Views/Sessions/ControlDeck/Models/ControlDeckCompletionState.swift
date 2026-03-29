import Foundation

struct ControlDeckCompletionState: Equatable {
  var mode: ControlDeckCompletionMode = .inactive
  var selectedIndex: Int = 0

  var isActive: Bool {
    mode != .inactive
  }

  var query: String {
    switch mode {
      case .inactive: ""
      case let .mention(q): q
      case let .skill(q): q
      case let .command(q): q
    }
  }

  mutating func activate(_ newMode: ControlDeckCompletionMode) {
    mode = newMode
    selectedIndex = 0
  }

  mutating func dismiss() {
    mode = .inactive
    selectedIndex = 0
  }

  mutating func moveUp() {
    selectedIndex = max(0, selectedIndex - 1)
  }

  mutating func moveDown(itemCount: Int) {
    selectedIndex = min(max(0, itemCount - 1), selectedIndex + 1)
  }
}

enum ControlDeckCompletionMode: Equatable {
  case inactive
  case mention(query: String)
  case skill(query: String)
  case command(query: String)
}

struct ControlDeckCompletionSuggestion: Identifiable, Equatable {
  let id: String
  let kind: Kind
  let title: String
  let subtitle: String?

  enum Kind: Equatable {
    case file
    case skill
    case command
  }
}
