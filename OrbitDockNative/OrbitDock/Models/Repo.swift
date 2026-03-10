//
//  Repo.swift
//  OrbitDock
//

import Foundation

struct Repo: Identifiable, Hashable {
  let id: String
  let name: String
  let path: String
  let githubOwner: String?
  let githubName: String?
  let createdAt: Date

  var githubFullName: String? {
    guard let owner = githubOwner, let name = githubName else { return nil }
    return "\(owner)/\(name)"
  }

  var githubURL: URL? {
    guard let fullName = githubFullName else { return nil }
    return URL(string: "https://github.com/\(fullName)")
  }
}
