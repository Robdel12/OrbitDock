import Foundation

struct ControlDeckSkill: Identifiable, Equatable, Sendable {
  let name: String
  let path: String
  let description: String
  let shortDescription: String?

  var id: String {
    path
  }
}
