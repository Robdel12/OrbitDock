//
//  Project.swift
//  OrbitDock
//

import Foundation

struct Project: Identifiable, Equatable {
    let id: String
    var name: String
    var description: String?
    var color: String?
    var status: Status
    let createdAt: Date
    var updatedAt: Date

    // Relationships (populated separately, excluded from Equatable)
    var workstreams: [Workstream]?

    static func == (lhs: Project, rhs: Project) -> Bool {
        lhs.id == rhs.id
    }

    enum Status: String {
        case active
        case completed
        case archived
    }

    // MARK: - Computed Properties

    var activeWorkstreamCount: Int {
        workstreams?.filter { $0.isActive }.count ?? 0
    }

    var totalWorkstreamCount: Int {
        workstreams?.count ?? 0
    }

    var repoNames: [String] {
        guard let workstreams = workstreams else { return [] }
        let names = Set(workstreams.compactMap { $0.repo?.name })
        return Array(names).sorted()
    }

    var statusIcon: String {
        switch status {
        case .active: return "circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .archived: return "archivebox.fill"
        }
    }
}
