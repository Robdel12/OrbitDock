import Foundation

enum DashboardScrollIDs {
  static func session(_ scopedID: String) -> String {
    "dashboard-session-\(scopedID)"
  }
}
