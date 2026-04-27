use std::fs;
use std::path::Path;

use tempfile::tempdir;

use super::{
  append_profile_entry, detect_shell_kind, path_has_entry, profile_contains_bin_dir,
  profile_path_for_shell, render_path_line, ShellKind,
};

#[test]
fn detect_shell_kind_supports_common_shells() {
  assert_eq!(detect_shell_kind(Some("/bin/zsh")), ShellKind::Zsh);
  assert_eq!(
    detect_shell_kind(Some("/usr/local/bin/bash")),
    ShellKind::Bash
  );
  assert_eq!(detect_shell_kind(Some("fish")), ShellKind::Fish);
  assert_eq!(detect_shell_kind(Some("nu")), ShellKind::Other);
  assert_eq!(detect_shell_kind(None), ShellKind::Bash);
}

#[test]
fn profile_path_for_shell_prefers_bash_profile_when_present() {
  let temp = tempdir().expect("tempdir");
  let home = temp.path();

  assert_eq!(
    profile_path_for_shell(home, ShellKind::Bash),
    home.join(".bashrc")
  );

  fs::write(home.join(".bash_profile"), "# bash profile").expect("write .bash_profile");
  assert_eq!(
    profile_path_for_shell(home, ShellKind::Bash),
    home.join(".bash_profile")
  );
}

#[test]
fn path_has_entry_matches_exact_component() {
  let target = Path::new("/Users/test/.orbitdock/bin");
  assert!(path_has_entry(
    Some("/usr/bin:/Users/test/.orbitdock/bin:/bin"),
    target
  ));
  assert!(path_has_entry(
    Some("/usr/bin:/Users/test/.orbitdock/bin/:/bin"),
    target
  ));
  assert!(!path_has_entry(Some("/usr/bin:/opt/homebrew/bin"), target));
}

#[test]
fn render_and_append_profile_entry_for_zsh() {
  let temp = tempdir().expect("tempdir");
  let profile_path = temp.path().join(".zshrc");
  let bin_dir = Path::new("/tmp/orbit dock/bin");
  let line = render_path_line(ShellKind::Zsh, bin_dir);

  append_profile_entry(&profile_path, &line).expect("append profile entry");

  let content = fs::read_to_string(&profile_path).expect("read profile");
  assert!(content.contains("# Added by OrbitDock installer"));
  assert!(content.contains("export PATH=\"/tmp/orbit dock/bin:$PATH\""));
  assert!(profile_contains_bin_dir(&profile_path, bin_dir).expect("profile contains path"));
}

#[test]
fn render_fish_path_line_quotes_path() {
  let line = render_path_line(ShellKind::Fish, Path::new("/tmp/orbit dock/bin"));
  assert_eq!(line, "fish_add_path \"/tmp/orbit dock/bin\"");
}
