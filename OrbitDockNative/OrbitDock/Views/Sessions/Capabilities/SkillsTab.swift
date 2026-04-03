//
//  SkillsTab.swift
//  OrbitDock
//
//  Interactive skills browser for sidebar: grouped by scope, toggle to attach.
//

import SwiftUI

struct SkillsTab: View {
  let sessionId: String
  let sessionStore: SessionStore
  @Binding var selectedSkills: Set<String>

  @State private var viewModel = SkillsTabViewModel()
  private var bindingIdentity: String {
    "\(sessionStore.endpointId.uuidString):\(sessionId):\(ObjectIdentifier(sessionStore))"
  }

  var body: some View {
    let skills = viewModel.skills
    let claudeSkillNames = viewModel.claudeSkillNames

    Group {
      if !skills.isEmpty {
        codexSkillsView
      } else if !claudeSkillNames.isEmpty {
        claudeSkillsView
      } else {
        EmptyView()
      }
    }
    .task(id: bindingIdentity) {
      viewModel.bind(sessionId: sessionId, sessionStore: sessionStore)
    }
  }

  // MARK: - Claude Skills (read-only name list)

  private var claudeSkillsView: some View {
    VStack(spacing: 0) {
      HStack(spacing: Spacing.sm_) {
        Text("\(viewModel.claudeSkillNames.count) skill\(viewModel.claudeSkillNames.count == 1 ? "" : "s")")
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
          ForEach(viewModel.claudeSkillNames, id: \.self) { name in
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
        Text("\(viewModel.skills.count) skill\(viewModel.skills.count == 1 ? "" : "s")")
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
          Task { await viewModel.refreshSkills() }
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
          ForEach(viewModel.groupedSkills, id: \.scope) { group in
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
        selectedSkills = viewModel.toggleSkillSelection(skill.path, selectedSkills: selectedSkills)
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
