//
//  SkillsPicker.swift
//  OrbitDock
//
//  Popover content for browsing and selecting skills to attach to messages.
//

import SwiftUI

struct SkillsPicker: View {
  let skills: [ServerSkillMetadata]
  @Binding var selectedSkills: Set<String>

  private let scopeOrder: [ServerSkillScope] = [.repo, .user, .system, .admin]

  private var groupedSkills: [(scope: ServerSkillScope, skills: [ServerSkillMetadata])] {
    scopeOrder.compactMap { scope in
      let matching = skills.filter { $0.scope == scope && $0.enabled }
      guard !matching.isEmpty else { return nil }
      return (scope, matching)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header
      HStack {
        Text("Skills")
          .font(.headline)
        Spacer()
        if !selectedSkills.isEmpty {
          Text("\(selectedSkills.count)")
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accent)
            .foregroundStyle(.white)
            .clipShape(Capsule())
        }
      }
      .padding(.horizontal, 14)
      .padding(.top, 12)
      .padding(.bottom, 8)

      Divider()

      if skills.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "bolt.slash")
            .font(.title2)
            .foregroundStyle(.tertiary)
          Text("No skills available")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("Add skills to .codex/skills/")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(groupedSkills, id: \.scope) { group in
              VStack(alignment: .leading, spacing: 4) {
                // Scope header
                HStack(spacing: 4) {
                  Image(systemName: iconForScope(group.scope))
                    .font(.caption2)
                  Text(labelForScope(group.scope))
                    .font(.caption.bold())
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)

                // Skills in this scope
                ForEach(group.skills) { skill in
                  SkillRow(skill: skill, isSelected: selectedSkills.contains(skill.path)) {
                    if selectedSkills.contains(skill.path) {
                      selectedSkills.remove(skill.path)
                    } else {
                      selectedSkills.insert(skill.path)
                    }
                  }
                }
              }
            }
          }
          .padding(.vertical, 8)
        }
      }
    }
    .frame(width: 280)
    .frame(maxHeight: 360)
    .background(Color.backgroundPrimary)
  }

  private func iconForScope(_ scope: ServerSkillScope) -> String {
    switch scope {
      case .repo: return "folder"
      case .user: return "person"
      case .system: return "gearshape"
      case .admin: return "lock"
    }
  }

  private func labelForScope(_ scope: ServerSkillScope) -> String {
    switch scope {
      case .repo: return "Project"
      case .user: return "User"
      case .system: return "System"
      case .admin: return "Admin"
    }
  }
}

private struct SkillRow: View {
  let skill: ServerSkillMetadata
  let isSelected: Bool
  let onToggle: () -> Void

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: 10) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.body)
          .foregroundStyle(isSelected ? AnyShapeStyle(Color.accent) : AnyShapeStyle(.tertiary))

        VStack(alignment: .leading, spacing: 2) {
          Text(skill.name)
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
          if let desc = skill.shortDescription ?? Optional(skill.description), !desc.isEmpty {
            Text(desc)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }

        Spacer()
      }
      .contentShape(Rectangle())
      .padding(.horizontal, 14)
      .padding(.vertical, 4)
    }
    .buttonStyle(.plain)
  }
}
