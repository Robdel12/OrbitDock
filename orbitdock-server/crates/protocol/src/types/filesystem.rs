use serde::Serialize;

#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct DirectoryEntry {
  pub name: String,
  pub is_dir: bool,
  pub is_git: bool,
}

#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct RecentProject {
  pub path: String,
  pub session_count: u32,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub last_active: Option<String>,
}
