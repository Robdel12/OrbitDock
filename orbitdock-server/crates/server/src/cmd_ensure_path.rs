//! `orbitdock-server ensure-path` — ensure the server binary directory is on PATH.
//!
//! Adds the current binary directory to a shell profile when missing so
//! `orbitdock-server` is easy to run from terminal sessions.

use std::ffi::OsStr;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ShellKind {
    Zsh,
    Bash,
    Fish,
    Other,
}

pub fn run() -> anyhow::Result<()> {
    let binary_path = std::env::current_exe().context("failed to resolve current executable")?;
    let bin_dir = binary_path.parent().ok_or_else(|| {
        anyhow!(
            "failed to resolve binary directory from {}",
            binary_path.display()
        )
    })?;
    let home_dir = dirs::home_dir().ok_or_else(|| anyhow!("HOME directory not found"))?;
    let shell_kind = detect_shell_kind(std::env::var("SHELL").ok().as_deref());
    let profile_path = profile_path_for_shell(&home_dir, shell_kind);

    if path_has_entry(std::env::var("PATH").ok().as_deref(), bin_dir) {
        println!();
        println!("  PATH already includes {}", bin_dir.display());
        println!();
        return Ok(());
    }

    if profile_contains_bin_dir(&profile_path, bin_dir)? {
        println!();
        println!("  PATH entry already present in {}", profile_path.display());
        println!();
        return Ok(());
    }

    let line = render_path_line(shell_kind, bin_dir);
    append_profile_entry(&profile_path, &line)?;

    println!();
    println!(
        "  Added {} to PATH in {}",
        bin_dir.display(),
        profile_path.display()
    );
    println!("  Restart your terminal, or run:");
    match shell_kind {
        ShellKind::Fish => println!("    fish_add_path {}", quote_for_shell(bin_dir)),
        _ => println!(
            "    export PATH=\"{}:$PATH\"",
            escape_for_double_quotes(bin_dir)
        ),
    }
    println!();

    Ok(())
}

fn detect_shell_kind(shell_env: Option<&str>) -> ShellKind {
    let raw = shell_env.unwrap_or("/bin/bash");
    let name = Path::new(raw)
        .file_name()
        .and_then(OsStr::to_str)
        .unwrap_or(raw)
        .to_ascii_lowercase();

    match name.as_str() {
        "zsh" => ShellKind::Zsh,
        "bash" => ShellKind::Bash,
        "fish" => ShellKind::Fish,
        _ => ShellKind::Other,
    }
}

fn profile_path_for_shell(home_dir: &Path, shell_kind: ShellKind) -> PathBuf {
    match shell_kind {
        ShellKind::Zsh => home_dir.join(".zshrc"),
        ShellKind::Bash => {
            let bash_profile = home_dir.join(".bash_profile");
            if bash_profile.exists() {
                bash_profile
            } else {
                home_dir.join(".bashrc")
            }
        }
        ShellKind::Fish => home_dir.join(".config/fish/config.fish"),
        ShellKind::Other => home_dir.join(".profile"),
    }
}

fn render_path_line(shell_kind: ShellKind, bin_dir: &Path) -> String {
    match shell_kind {
        ShellKind::Fish => format!("fish_add_path {}", quote_for_shell(bin_dir)),
        _ => format!(
            "export PATH=\"{}:$PATH\"",
            escape_for_double_quotes(bin_dir)
        ),
    }
}

fn quote_for_shell(path: &Path) -> String {
    format!("\"{}\"", escape_for_double_quotes(path))
}

fn escape_for_double_quotes(path: &Path) -> String {
    path.to_string_lossy()
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
}

fn normalize_path_component(value: &str) -> String {
    let trimmed = value.trim();
    if trimmed == "/" {
        "/".to_string()
    } else {
        trimmed.trim_end_matches('/').to_string()
    }
}

fn path_has_entry(path_env: Option<&str>, target_dir: &Path) -> bool {
    let Some(path_env) = path_env else {
        return false;
    };

    let target = normalize_path_component(&target_dir.to_string_lossy());
    path_env.split(':').any(|entry| {
        if entry.trim().is_empty() {
            return false;
        }
        normalize_path_component(entry) == target
    })
}

fn profile_contains_bin_dir(profile_path: &Path, bin_dir: &Path) -> anyhow::Result<bool> {
    if !profile_path.exists() {
        return Ok(false);
    }

    let content = std::fs::read_to_string(profile_path)
        .with_context(|| format!("failed to read {}", profile_path.display()))?;
    let target = bin_dir.to_string_lossy();
    Ok(content.lines().any(|line| line.contains(target.as_ref())))
}

fn append_profile_entry(profile_path: &Path, line: &str) -> anyhow::Result<()> {
    if let Some(parent) = profile_path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }

    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(profile_path)
        .with_context(|| format!("failed to open {}", profile_path.display()))?;
    writeln!(file)?;
    writeln!(file, "# Added by OrbitDock installer")?;
    writeln!(file, "{line}")?;
    Ok(())
}

#[cfg(test)]
mod tests {
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
}
