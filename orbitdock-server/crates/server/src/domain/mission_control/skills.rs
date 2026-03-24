//! Resolve skill names from MISSION.md config for Codex and Claude dispatch.

use std::path::PathBuf;

use orbitdock_protocol::SkillInput;
use tracing::warn;

/// Build the SKILL.md path for a given root, provider directory, and skill name.
///
/// Skills live at `{root}/{provider_dir}/skills/{name}/SKILL.md`.
fn skill_path(root: &std::path::Path, provider_dir: &str, name: &str) -> PathBuf {
    root.join(provider_dir)
        .join("skills")
        .join(name)
        .join("SKILL.md")
}

/// Locate the SKILL.md file for a given skill name and provider directory.
///
/// Resolution order:
/// 1. `~/{provider_dir}/skills/{name}/SKILL.md`
/// 2. `{cwd}/.*/skills/{name}/SKILL.md`, walking current-dir ancestors toward `/`
fn find_skill_path(
    home: Option<&std::path::Path>,
    cwd: Option<&std::path::Path>,
    provider_dir: &str,
    name: &str,
) -> Option<PathBuf> {
    if let Some(home) = home {
        let home_path = skill_path(home, provider_dir, name);
        if home_path.exists() {
            return Some(home_path);
        }
    }

    if let Some(cwd) = cwd {
        for dir in cwd.ancestors() {
            let candidate = skill_path(dir, provider_dir, name);
            if candidate.exists() {
                return Some(candidate);
            }
        }
    }

    None
}

/// Resolve a list of skill names into `SkillInput` values for Codex dispatch.
///
/// Each name is looked up first at `~/.codex/skills/{name}/SKILL.md`, then
/// in repo-local `.codex/skills/{name}/SKILL.md` by walking current-dir ancestors.
/// Missing skills are logged and skipped.
pub fn resolve_skill_inputs(skill_names: &[String]) -> Vec<SkillInput> {
    if skill_names.is_empty() {
        return vec![];
    }

    let home = dirs::home_dir();
    let cwd = std::env::current_dir().ok();
    if home.is_none() && cwd.is_none() {
        warn!(
            component = "mission_control",
            event = "skills.no_resolution_roots",
            provider = "codex",
            "Cannot resolve Codex skills: neither home directory nor current directory is available"
        );
        return vec![];
    }

    let mut resolved = Vec::with_capacity(skill_names.len());
    for name in skill_names {
        if let Some(skill_path) = find_skill_path(home.as_deref(), cwd.as_deref(), ".codex", name) {
            resolved.push(SkillInput {
                name: name.clone(),
                path: skill_path.to_string_lossy().to_string(),
            });
        } else {
            warn!(
                component = "mission_control",
                event = "skills.not_found",
                skill_name = %name,
                provider = "codex",
                "Configured mission skill not found on disk — skipping"
            );
        }
    }

    resolved
}

/// Read skill content for Claude prompt injection.
///
/// Claude doesn't have a `skills` field on `SendMessage`, so we read each
/// skill's SKILL.md content and return it for prepending to the prompt.
/// Skills are looked up first at `~/.claude/skills/{name}/SKILL.md`, then
/// in repo-local `.claude/skills/{name}/SKILL.md` by walking current-dir ancestors.
/// Missing skills are logged and skipped.
pub fn read_skill_content_for_claude(skill_names: &[String]) -> Option<String> {
    if skill_names.is_empty() {
        return None;
    }

    let home = dirs::home_dir();
    let cwd = std::env::current_dir().ok();
    if home.is_none() && cwd.is_none() {
        warn!(
            component = "mission_control",
            event = "skills.no_resolution_roots",
            provider = "claude",
            "Cannot resolve Claude skills: neither home directory nor current directory is available"
        );
        return None;
    }

    let mut sections = Vec::new();
    for name in skill_names {
        if let Some(skill_path) = find_skill_path(home.as_deref(), cwd.as_deref(), ".claude", name)
        {
            match std::fs::read_to_string(&skill_path) {
                Ok(content) => {
                    // Strip YAML front matter — the agent doesn't need the metadata
                    let body = strip_front_matter(&content);
                    if !body.trim().is_empty() {
                        sections.push(body.to_string());
                    }
                }
                Err(err) => {
                    warn!(
                        component = "mission_control",
                        event = "skills.read_failed",
                        skill_name = %name,
                        path = %skill_path.display(),
                        error = %err,
                        "Failed to read Claude skill file — skipping"
                    );
                }
            }
        } else {
            warn!(
                component = "mission_control",
                event = "skills.not_found",
                skill_name = %name,
                provider = "claude",
                "Configured mission skill not found on disk — skipping"
            );
        }
    }

    if sections.is_empty() {
        None
    } else {
        Some(sections.join("\n\n"))
    }
}

/// Strip YAML front matter (between `---` markers) from a skill file.
fn strip_front_matter(content: &str) -> &str {
    let trimmed = content.trim_start();
    if !trimmed.starts_with("---") {
        return content;
    }
    // Find the closing `---`
    if let Some(end) = trimmed[3..].find("\n---") {
        // Skip past the closing `---` and the newline after it
        let after = &trimmed[3 + end + 4..];
        after.trim_start_matches('\n')
    } else {
        content
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn write_skill(
        root: &std::path::Path,
        provider_dir: &str,
        name: &str,
        content: &str,
    ) -> PathBuf {
        let path = skill_path(root, provider_dir, name);
        std::fs::create_dir_all(path.parent().expect("skill parent")).expect("create skill dir");
        std::fs::write(&path, content).expect("write skill");
        path
    }

    #[test]
    fn empty_names_returns_empty() {
        assert!(resolve_skill_inputs(&[]).is_empty());
    }

    #[test]
    fn empty_names_returns_none_for_claude() {
        assert!(read_skill_content_for_claude(&[]).is_none());
    }

    #[test]
    fn missing_skill_is_skipped() {
        let result = resolve_skill_inputs(&["nonexistent-skill-abc123".to_string()]);
        assert!(result.is_empty());
    }

    #[test]
    fn missing_claude_skill_is_skipped() {
        let result = read_skill_content_for_claude(&["nonexistent-skill-abc123".to_string()]);
        assert!(result.is_none());
    }

    #[test]
    fn find_skill_path_prefers_home_before_repo_local() {
        let home = TempDir::new().expect("home tempdir");
        let repo = TempDir::new().expect("repo tempdir");
        let expected = write_skill(home.path(), ".codex", "testing-philosophy", "# home");
        write_skill(repo.path(), ".codex", "testing-philosophy", "# repo");

        let resolved = find_skill_path(
            Some(home.path()),
            Some(repo.path()),
            ".codex",
            "testing-philosophy",
        );

        assert_eq!(resolved, Some(expected));
    }

    #[test]
    fn find_skill_path_falls_back_to_repo_local_ancestor() {
        let repo = TempDir::new().expect("repo tempdir");
        let nested = repo
            .path()
            .join("orbitdock-server")
            .join("crates")
            .join("server");
        std::fs::create_dir_all(&nested).expect("nested cwd");
        let expected = write_skill(repo.path(), ".codex", "rust-server-architecture", "# repo");

        let resolved = find_skill_path(None, Some(&nested), ".codex", "rust-server-architecture");

        assert_eq!(resolved, Some(expected));
    }

    #[test]
    fn find_skill_path_returns_none_when_missing_everywhere() {
        let repo = TempDir::new().expect("repo tempdir");
        assert_eq!(
            find_skill_path(None, Some(repo.path()), ".codex", "missing-skill"),
            None
        );
    }

    #[test]
    fn strip_front_matter_keeps_claude_skill_body_clean() {
        let repo = TempDir::new().expect("repo tempdir");
        let path = write_skill(
            repo.path(),
            ".claude",
            "testing-philosophy",
            "---\nname: testing-philosophy\ndescription: test\n---\n\n# Heading\nBody",
        );

        let content = std::fs::read_to_string(path).expect("read skill");
        assert_eq!(strip_front_matter(&content), "# Heading\nBody");
    }

    #[test]
    fn strip_front_matter_removes_yaml() {
        let input = "---\nname: foo\ndescription: bar\n---\n\n# Content\nBody here";
        assert_eq!(strip_front_matter(input), "# Content\nBody here");
    }

    #[test]
    fn strip_front_matter_no_front_matter() {
        let input = "# Just content\nNo front matter";
        assert_eq!(strip_front_matter(input), input);
    }
}
