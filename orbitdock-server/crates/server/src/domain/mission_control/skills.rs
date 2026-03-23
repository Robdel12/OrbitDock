//! Resolve skill names from MISSION.md config for Codex and Claude dispatch.

use std::path::PathBuf;

use orbitdock_protocol::SkillInput;
use tracing::warn;

/// Locate the SKILL.md file for a given skill name and provider directory.
///
/// Skills live at `~/{provider_dir}/skills/{name}/SKILL.md`
/// (e.g. `~/.codex/skills/testing-philosophy/SKILL.md`).
fn find_skill_path(home: &std::path::Path, provider_dir: &str, name: &str) -> Option<PathBuf> {
    let path = home
        .join(provider_dir)
        .join("skills")
        .join(name)
        .join("SKILL.md");

    if path.exists() {
        Some(path)
    } else {
        None
    }
}

/// Resolve a list of skill names into `SkillInput` values for Codex dispatch.
///
/// Each name is looked up at `~/.codex/skills/{name}/SKILL.md`.
/// Missing skills are logged and skipped.
pub fn resolve_skill_inputs(skill_names: &[String]) -> Vec<SkillInput> {
    if skill_names.is_empty() {
        return vec![];
    }

    let home = match dirs::home_dir() {
        Some(h) => h,
        None => {
            warn!(
                component = "mission_control",
                event = "skills.no_home_dir",
                "Cannot resolve Codex skills: home directory not found"
            );
            return vec![];
        }
    };

    let mut resolved = Vec::with_capacity(skill_names.len());
    for name in skill_names {
        if let Some(skill_path) = find_skill_path(&home, ".codex", name) {
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
/// Skills are looked up at `~/.claude/skills/{name}/SKILL.md`.
/// Missing skills are logged and skipped.
pub fn read_skill_content_for_claude(skill_names: &[String]) -> Option<String> {
    if skill_names.is_empty() {
        return None;
    }

    let home = match dirs::home_dir() {
        Some(h) => h,
        None => {
            warn!(
                component = "mission_control",
                event = "skills.no_home_dir",
                "Cannot resolve Claude skills: home directory not found"
            );
            return None;
        }
    };

    let mut sections = Vec::new();
    for name in skill_names {
        if let Some(skill_path) = find_skill_path(&home, ".claude", name) {
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
