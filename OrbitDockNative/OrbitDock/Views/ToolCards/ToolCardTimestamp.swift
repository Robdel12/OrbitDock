import Foundation

enum ToolCardTimestamp {
  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter
  }()

  static func format(_ date: Date) -> String {
    formatter.string(from: date)
  }
}
