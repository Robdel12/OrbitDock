//
//  SkillsTab.swift
//  OrbitDock
//
//  Interactive skills browser for sidebar: grouped by scope, toggle to attach.
//

import SwiftUI

struct SkillsTab: View {
  let sessionId: String
  @Binding var selectedSkills: Set<String>

  @Environment(ServerAppState.self) private var serverState

  private let scopeOrder: [ServerSkillScope] = [.repo, .user, .system, .admin]

  private var skills: [ServerSkillMetadata] {
    (serverState.sessionSkills[sessionId] ?? []).filter { $0.enabled }
  }

  private var groupedSkills: [(scope: ServerSkillScope, skills: [ServerSkillMetadata])] {
    scopeOrder.compactMap { scope in
      let matching = skills.filter { $0.scope == scope }
      guard !matching.isEmpty else { return nil }
      return (scope, matching)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack(spacing: 6) {
        Text("\(skills.count) skill\(skills.count == 1 ? "" : "s")")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)

        if !selectedSkills.isEmpty {
          Text("·")
            .foregroundStyle(.quaternary)
          Text("\(selectedSkills.count) attached")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.accent)
        }

        Spacer()

        Button {
          serverState.listSkills(sessionId: sessionId)
        } label: {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("Refresh skills")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      Divider()
        .foregroundStyle(Color.panelBorder.opacity(0.5))

      // Skills list grouped by scope
      ScrollView(.vertical, showsIndicators: true) {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(groupedSkills, id: \.scope) { group in
            VStack(alignment: .leading, spacing: 4) {
              // Scope header
              HStack(spacing: 4) {
                Image(systemName: iconForScope(group.scope))
                  .font(.system(size: 10, weight: .medium))
                Text(labelForScope(group.scope))
                  .font(.system(size: 10, weight: .bold))
              }
              .foregroundStyle(.secondary)
              .padding(.horizontal, 12)

              // Skills in this scope
              ForEach(group.skills) { skill in
                skillRow(skill)
              }
            }
          }
        }
        .padding(.vertical, 8)
      }
    }
    .background(Color.backgroundPrimary)
  }

  // MARK: - Skill Row

  private func skillRow(_ skill: ServerSkillMetadata) -> some View {
    let isAttached = selectedSkills.contains(skill.path)

    return Button {
      withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
        if isAttached {
          selectedSkills.remove(skill.path)
        } else {
          selectedSkills.insert(skill.path)
        }
      }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: isAttached ? "checkmark.circle.fill" : "bolt.fill")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(isAttached ? Color.accent : Color.toolSkill)

        VStack(alignment: .leading, spacing: 2) {
          Text(skill.name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)

          if let desc = skill.shortDescription ?? Optional(skill.description), !desc.isEmpty {
            Text(desc)
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(isAttached ? Color.accent.opacity(0.08) : Color.clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  // MARK: - Helpers

  private func iconForScope(_ scope: ServerSkillScope) -> String {
    switch scope {
      case .repo: "folder"
      case .user: "person"
      case .system: "gearshape"
      case .admin: "lock"
    }
  }

  private func labelForScope(_ scope: ServerSkillScope) -> String {
    switch scope {
      case .repo: "Project"
      case .user: "User"
      case .system: "System"
      case .admin: "Admin"
    }
  }
}
