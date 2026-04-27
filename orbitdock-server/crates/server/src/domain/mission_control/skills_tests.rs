use super::*;
use tempfile::TempDir;

fn write_skill(root: &std::path::Path, provider_dir: &str, name: &str, content: &str) -> PathBuf {
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
