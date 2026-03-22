//! Resolve skill names from MISSION.md config into `SkillInput` values.

use orbitdock_protocol::SkillInput;
use tracing::warn;

/// Resolve a list of skill names into `SkillInput` values by locating their
/// SKILL.md files on disk. Skills that cannot be found are logged and skipped.
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
                "Cannot resolve skills: home directory not found"
            );
            return vec![];
        }
    };

    let mut resolved = Vec::with_capacity(skill_names.len());
    for name in skill_names {
        // Codex skills live at ~/.codex/skills/{name}/SKILL.md
        let skill_path = home
            .join(".codex")
            .join("skills")
            .join(name)
            .join("SKILL.md");

        if skill_path.exists() {
            resolved.push(SkillInput {
                name: name.clone(),
                path: skill_path.to_string_lossy().to_string(),
            });
        } else {
            warn!(
                component = "mission_control",
                event = "skills.not_found",
                skill_name = %name,
                expected_path = %skill_path.display(),
                "Configured mission skill not found on disk — skipping"
            );
        }
    }

    resolved
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_names_returns_empty() {
        assert!(resolve_skill_inputs(&[]).is_empty());
    }

    #[test]
    fn missing_skill_is_skipped() {
        let result = resolve_skill_inputs(&["nonexistent-skill-abc123".to_string()]);
        assert!(result.is_empty());
    }
}
