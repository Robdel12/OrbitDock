pub(crate) fn project_name_from_cwd(cwd: &str) -> Option<String> {
    std::path::Path::new(cwd)
        .file_name()
        .and_then(|s| s.to_str())
        .map(|s| s.to_string())
}

pub(crate) fn claude_transcript_path_from_cwd(cwd: &str, session_id: &str) -> Option<String> {
    let home = std::env::var("HOME").ok()?;
    let trimmed = cwd.trim_start_matches('/');
    if trimmed.is_empty() {
        return None;
    }
    let dir = format!("-{}", trimmed.replace('/', "-"));
    Some(format!(
        "{}/.claude/projects/{}/{}.jsonl",
        home, dir, session_id
    ))
}

/// Resolve the correct cwd for `claude --resume` by matching the transcript
/// path's project hash against the session's project_path (and its parents).
///
/// Claude stores transcripts at `~/.claude/projects/<hash>/<session>.jsonl`
/// where `<hash>` encodes the cwd with `/` and `.` replaced by `-`.
/// The DB's `project_path` may be a subdirectory, so we walk up until
/// we find a path whose hash matches the transcript's project directory.
pub(crate) fn resolve_claude_resume_cwd(project_path: &str, transcript_path: &str) -> String {
    let expected_hash = std::path::Path::new(transcript_path)
        .parent()
        .and_then(|p| p.file_name())
        .and_then(|n| n.to_str());

    let Some(expected) = expected_hash else {
        return project_path.to_string();
    };

    let mut candidate = std::path::PathBuf::from(project_path);
    for _ in 0..5 {
        let hash = candidate.to_string_lossy().replace(['/', '.'], "-");
        if hash == expected {
            return candidate.to_string_lossy().to_string();
        }
        if !candidate.pop() {
            break;
        }
    }

    project_path.to_string()
}

#[cfg(test)]
mod tests {
    use super::claude_transcript_path_from_cwd;

    #[test]
    fn claude_transcript_path_derives_project_hash_from_cwd() {
        let path =
            claude_transcript_path_from_cwd("/Users/robertdeluca/Developer/vizzly-cli", "abc-123");
        let value = path.expect("expected transcript path");
        assert!(
            value.ends_with(
                "/.claude/projects/-Users-robertdeluca-Developer-vizzly-cli/abc-123.jsonl"
            ),
            "unexpected transcript path: {}",
            value
        );
    }
}
