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
    serverState.session(sessionId).skills.filter(\.enabled)
  }

  private var claudeSkillNames: [String] {
    serverState.session(sessionId).claudeSkillNames.sorted()
  }

  private var groupedSkills: [(scope: ServerSkillScope, skills: [ServerSkillMetadata])] {
    scopeOrder.compactMap { scope in
      let matching = skills.filter { $0.scope == scope }
      guard !matching.isEmpty else { return nil }
      return (scope, matching)
    }
  }

  var body: some View {
    if !skills.isEmpty {
      codexSkillsView
    } else if !claudeSkillNames.isEmpty {
      claudeSkillsView
    }
  }

  // MARK: - Claude Skills (read-only name list)

  private var claudeSkillsView: some View {
    VStack(spacing: 0) {
      HStack(spacing: Spacing.sm_) {
        Text("\(claudeSkillNames.count) skill\(claudeSkillNames.count == 1 ? "" : "s")")
          .font(.system(size: TypeScale.meta, weight: .medium))
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)

      Divider()
        .foregroundStyle(Color.panelBorder.opacity(0.5))

      ScrollView(.vertical, showsIndicators: true) {
        LazyVStack(alignment: .leading, spacing: Spacing.xxs) {
          ForEach(claudeSkillNames, id: \.self) { name in
            HStack(spacing: Spacing.sm) {
              Image(systemName: "bolt.fill")
                .font(.system(size: TypeScale.meta, weight: .medium))
                .foregroundStyle(Color.toolSkill)

              Text(name)
                .font(.system(size: TypeScale.caption, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

              Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm_)
          }
        }
        .padding(.vertical, Spacing.sm)
      }
    }
    .background(Color.backgroundPrimary)
  }

  // MARK: - Codex Skills (interactive, grouped by scope)

  private var codexSkillsView: some View {
    VStack(spacing: 0) {
      // Header
      HStack(spacing: Spacing.sm_) {
        Text("\(skills.count) skill\(skills.count == 1 ? "" : "s")")
          .font(.system(size: TypeScale.meta, weight: .medium))
          .foregroundStyle(.secondary)

        if !selectedSkills.isEmpty {
          Text("·")
            .foregroundStyle(Color.textQuaternary)
          Text("\(selectedSkills.count) attached")
            .font(.system(size: TypeScale.meta, weight: .medium))
            .foregroundStyle(Color.accent)
        }

        Spacer()

        Button {
          serverState.listSkills(sessionId: sessionId)
        } label: {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: TypeScale.meta, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .help("Refresh skills")
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)

      Divider()
        .foregroundStyle(Color.panelBorder.opacity(0.5))

      // Skills list grouped by scope
      ScrollView(.vertical, showsIndicators: true) {
        LazyVStack(alignment: .leading, spacing: Spacing.md) {
          ForEach(groupedSkills, id: \.scope) { group in
            VStack(alignment: .leading, spacing: Spacing.xs) {
              // Scope header
              HStack(spacing: Spacing.xs) {
                Image(systemName: iconForScope(group.scope))
                  .font(.system(size: TypeScale.micro, weight: .medium))
                Text(labelForScope(group.scope))
                  .font(.system(size: TypeScale.micro, weight: .bold))
              }
              .foregroundStyle(.secondary)
              .padding(.horizontal, Spacing.md)

              // Skills in this scope
              ForEach(group.skills) { skill in
                skillRow(skill)
              }
            }
          }
        }
        .padding(.vertical, Spacing.sm)
      }
    }
    .background(Color.backgroundPrimary)
  }

  // MARK: - Skill Row

  private func skillRow(_ skill: ServerSkillMetadata) -> some View {
    let isAttached = selectedSkills.contains(skill.path)

    return Button {
      withAnimation(Motion.snappy) {
        if isAttached {
          selectedSkills.remove(skill.path)
        } else {
          selectedSkills.insert(skill.path)
        }
      }
    } label: {
      HStack(spacing: Spacing.sm) {
        Image(systemName: isAttached ? "checkmark.circle.fill" : "bolt.fill")
          .font(.system(size: TypeScale.meta, weight: .medium))
          .foregroundStyle(isAttached ? Color.accent : Color.toolSkill)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(skill.name)
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)

          if let desc = skill.shortDescription ?? Optional(skill.description), !desc.isEmpty {
            Text(desc)
              .font(.system(size: TypeScale.meta))
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }

        Spacer(minLength: 0)
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm_)
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
