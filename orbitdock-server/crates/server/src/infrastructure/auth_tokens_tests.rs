use super::parse_token_candidates;

#[test]
fn parse_token_candidates_rejects_invalid_prefix() {
  let candidates = parse_token_candidates("invalid_token");
  assert!(candidates.is_empty());
}

#[test]
fn parse_token_candidates_supports_underscores_in_segments() {
  let token = "odtk_abc_def_ghi_jkl";
  let candidates = parse_token_candidates(token);
  assert!(candidates
    .iter()
    .any(|(id, secret)| *id == "abc_def" && *secret == "ghi_jkl"));
}
