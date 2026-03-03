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
            .padding(.horizontal, Spacing.sm_)
            .padding(.vertical, Spacing.xxs)
            .background(Color.accent)
            .foregroundStyle(.white)
            .clipShape(Capsule())
        }
      }
      .padding(.horizontal, Spacing.lg_)
      .padding(.top, Spacing.md)
      .padding(.bottom, Spacing.sm)

      Divider()

      if skills.isEmpty {
        VStack(spacing: Spacing.sm) {
          Image(systemName: "bolt.slash")
            .font(.title2)
            .foregroundStyle(Color.textTertiary)
          Text("No skills available")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("Add skills to .codex/skills/")
            .font(.caption2)
            .foregroundStyle(Color.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.md) {
            ForEach(groupedSkills, id: \.scope) { group in
              VStack(alignment: .leading, spacing: Spacing.xs) {
                // Scope header
                HStack(spacing: Spacing.xs) {
                  Image(systemName: iconForScope(group.scope))
                    .font(.caption2)
                  Text(labelForScope(group.scope))
                    .font(.caption.bold())
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.lg_)

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
          .padding(.vertical, Spacing.sm)
        }
      }
    }
    .frame(width: 280)
    .frame(maxHeight: 360)
    .background(Color.backgroundPrimary)
  }

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

private struct SkillRow: View {
  let skill: ServerSkillMetadata
  let isSelected: Bool
  let onToggle: () -> Void

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: Spacing.md_) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.body)
          .foregroundStyle(isSelected ? AnyShapeStyle(Color.accent) : AnyShapeStyle(Color.textTertiary))

        VStack(alignment: .leading, spacing: Spacing.xxs) {
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
      .padding(.horizontal, Spacing.lg_)
      .padding(.vertical, Spacing.xs)
    }
    .buttonStyle(.plain)
  }
}
