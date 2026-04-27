use super::claude_transcript_path_from_cwd;

#[test]
fn claude_transcript_path_derives_project_hash_from_cwd() {
  let path = claude_transcript_path_from_cwd("/Users/robertdeluca/Developer/vizzly-cli", "abc-123");
  let value = path.expect("expected transcript path");
  assert!(
    value.ends_with("/.claude/projects/-Users-robertdeluca-Developer-vizzly-cli/abc-123.jsonl"),
    "unexpected transcript path: {}",
    value
  );
}
