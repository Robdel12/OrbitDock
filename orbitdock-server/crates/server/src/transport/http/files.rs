use super::*;
use std::path::PathBuf;

use codex_core::config::find_codex_home;
use orbitdock_protocol::{DirectoryEntry, Message, RecentProject, SubagentTool};
use tracing::warn;

use crate::infrastructure::persistence::{
    load_messages_from_transcript_path, load_subagent_transcript_path,
};

#[derive(Debug, Serialize)]
pub struct DirectoryListingResponse {
    pub path: String,
    pub entries: Vec<DirectoryEntry>,
}

#[derive(Debug, Serialize)]
pub struct RecentProjectsResponse {
    pub projects: Vec<RecentProject>,
}

#[derive(Debug, Serialize)]
pub struct SubagentToolsResponse {
    pub session_id: String,
    pub subagent_id: String,
    pub tools: Vec<SubagentTool>,
}

#[derive(Debug, Serialize)]
pub struct SubagentMessagesResponse {
    pub session_id: String,
    pub subagent_id: String,
    pub messages: Vec<Message>,
}

#[derive(Debug, Deserialize)]
pub struct GitInitRequest {
    pub path: String,
}

#[derive(Debug, Serialize)]
pub struct GitInitResponse {
    ok: bool,
}

#[derive(Debug, Deserialize, Default)]
pub struct BrowseDirectoryQuery {
    #[serde(default)]
    pub path: Option<String>,
}

pub async fn browse_directory(
    Query(query): Query<BrowseDirectoryQuery>,
) -> Json<DirectoryListingResponse> {
    let target = resolve_browse_target(query.path.as_deref());

    let entries = match read_directory_entries(&target) {
        Ok(entries) => entries,
        Err(err) => {
            warn!(
                component = "api",
                event = "api.browse_directory.read_error",
                path = %target.display(),
                error = %err,
                "Cannot read directory"
            );
            vec![]
        }
    };

    Json(DirectoryListingResponse {
        path: target.to_string_lossy().to_string(),
        entries,
    })
}

pub async fn list_recent_projects(
    State(state): State<Arc<SessionRegistry>>,
) -> Json<RecentProjectsResponse> {
    Json(RecentProjectsResponse {
        projects: state.list_recent_projects().await,
    })
}

pub async fn list_subagent_tools_endpoint(
    Path((session_id, subagent_id)): Path<(String, String)>,
) -> Json<SubagentToolsResponse> {
    let tools = load_subagent_tools(&subagent_id).await;
    Json(SubagentToolsResponse {
        session_id,
        subagent_id,
        tools,
    })
}

pub async fn list_subagent_messages_endpoint(
    Path((session_id, subagent_id)): Path<(String, String)>,
) -> Json<SubagentMessagesResponse> {
    let messages = load_subagent_messages(&subagent_id).await;
    Json(SubagentMessagesResponse {
        session_id,
        subagent_id,
        messages,
    })
}

pub async fn git_init_endpoint(Json(body): Json<GitInitRequest>) -> ApiResult<GitInitResponse> {
    if tokio::fs::metadata(&body.path).await.is_err() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiErrorResponse {
                code: "path_not_found",
                error: format!("directory does not exist: {}", body.path),
            }),
        ));
    }

    crate::domain::git::repo::git_init(&body.path)
        .await
        .map(|_| Json(GitInitResponse { ok: true }))
        .map_err(|error| {
            (
                StatusCode::BAD_REQUEST,
                Json(ApiErrorResponse {
                    code: "git_init_failed",
                    error,
                }),
            )
        })
}

fn resolve_browse_target(path: Option<&str>) -> PathBuf {
    match path {
        Some(path) if !path.is_empty() => {
            if let Some(stripped) = path.strip_prefix('~') {
                if let Some(home) = dirs::home_dir() {
                    return home.join(stripped.trim_start_matches('/'));
                }
            }
            PathBuf::from(path)
        }
        _ => dirs::home_dir().unwrap_or_else(|| PathBuf::from("/")),
    }
}

fn read_directory_entries(target: &PathBuf) -> Result<Vec<DirectoryEntry>, std::io::Error> {
    let mut listing: Vec<DirectoryEntry> = Vec::new();

    for entry in std::fs::read_dir(target)? {
        let entry = match entry {
            Ok(entry) => entry,
            Err(_) => continue,
        };

        let meta = match entry.metadata() {
            Ok(meta) => meta,
            Err(_) => continue,
        };

        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with('.') {
            continue;
        }

        let is_dir = meta.is_dir();
        let is_git = if is_dir {
            entry.path().join(".git").exists()
        } else {
            false
        };

        listing.push(DirectoryEntry {
            name,
            is_dir,
            is_git,
        });
    }

    listing.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then(a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });

    Ok(listing)
}

async fn load_subagent_tools(subagent_id: &str) -> Vec<SubagentTool> {
    match resolve_subagent_transcript_path(subagent_id).await {
        Some(path) => {
            let parse_path = path.clone();
            tokio::task::spawn_blocking(move || {
                crate::connectors::subagent_parser::parse_tools(std::path::Path::new(&parse_path))
            })
            .await
            .unwrap_or_default()
        }
        None => vec![],
    }
}

async fn load_subagent_messages(subagent_id: &str) -> Vec<Message> {
    let Some(path) = resolve_subagent_transcript_path(subagent_id).await else {
        return vec![];
    };

    match load_messages_from_transcript_path(&path, subagent_id).await {
        Ok(messages) => messages,
        Err(err) => {
            warn!(
                component = "api",
                event = "api.subagent_messages.load_error",
                subagent_id = %subagent_id,
                transcript_path = %path,
                error = %err,
                "Failed to load subagent transcript messages"
            );
            vec![]
        }
    }
}

async fn resolve_subagent_transcript_path(subagent_id: &str) -> Option<String> {
    match load_subagent_transcript_path(subagent_id).await {
        Ok(Some(path)) => return Some(path),
        Ok(None) => {}
        Err(err) => {
            warn!(
                component = "api",
                event = "api.subagent_transcript.lookup_failed",
                subagent_id = %subagent_id,
                error = %err,
                "Failed to load persisted subagent transcript path"
            );
        }
    }

    let codex_home = match find_codex_home() {
        Ok(path) => path,
        Err(err) => {
            warn!(
                component = "api",
                event = "api.subagent_transcript.codex_home_failed",
                subagent_id = %subagent_id,
                error = %err,
                "Failed to resolve codex home while looking up subagent rollout"
            );
            return None;
        }
    };

    match codex_core::find_thread_path_by_id_str(&codex_home, subagent_id).await {
        Ok(Some(path)) => Some(path.to_string_lossy().to_string()),
        Ok(None) => None,
        Err(err) => {
            warn!(
                component = "api",
                event = "api.subagent_transcript.rollout_not_found",
                subagent_id = %subagent_id,
                error = %err,
                "No rollout found for subagent thread"
            );
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{extract::Path, extract::Query, Json};

    use crate::support::test_support::ensure_server_test_data_dir;

    #[tokio::test]
    async fn browse_directory_hides_dotfiles_and_returns_directories_first() {
        let root = std::env::temp_dir().join(format!(
            "orbitdock-api-browse-{}",
            orbitdock_protocol::new_id()
        ));
        std::fs::create_dir_all(root.join("z-dir")).expect("create visible directory");
        std::fs::write(root.join("a-file.txt"), "hello").expect("create visible file");
        std::fs::write(root.join(".hidden.txt"), "secret").expect("create hidden file");

        let Json(response) = browse_directory(Query(BrowseDirectoryQuery {
            path: Some(root.to_string_lossy().to_string()),
        }))
        .await;

        std::fs::remove_dir_all(&root).expect("remove browse test directory");

        assert_eq!(response.path, root.to_string_lossy().to_string());
        assert!(response
            .entries
            .iter()
            .any(|entry| entry.name == "z-dir" && entry.is_dir));
        assert!(response
            .entries
            .iter()
            .any(|entry| entry.name == "a-file.txt" && !entry.is_dir));
        assert!(!response
            .entries
            .iter()
            .any(|entry| entry.name.starts_with('.')));

        let first = response
            .entries
            .first()
            .expect("expected at least one listing entry");
        assert!(
            first.is_dir,
            "expected directories to be sorted before files"
        );
    }

    #[tokio::test]
    async fn subagent_tools_endpoint_returns_empty_when_subagent_missing() {
        ensure_server_test_data_dir();
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        let subagent_id = format!("sub-{}", orbitdock_protocol::new_id());

        let Json(response) =
            list_subagent_tools_endpoint(Path((session_id.clone(), subagent_id.clone()))).await;

        assert_eq!(response.session_id, session_id);
        assert_eq!(response.subagent_id, subagent_id);
        assert!(response.tools.is_empty());
    }

    #[tokio::test]
    async fn subagent_messages_endpoint_reads_transcript_messages() {
        ensure_server_test_data_dir();
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        let subagent_id = format!("sub-{}", orbitdock_protocol::new_id());
        let transcript_path = std::env::temp_dir().join(format!("{subagent_id}.jsonl"));
        std::fs::write(
            &transcript_path,
            r#"{"type":"message","role":"user","timestamp":"2026-03-11T05:00:00Z","content":[{"type":"text","text":"Inspect the auth flow"}]}
{"type":"message","role":"assistant","timestamp":"2026-03-11T05:00:02Z","content":[{"type":"text","text":"I found the auth coordinator in the runtime layer."}]}
"#,
        )
        .expect("write transcript");

        let db_path = crate::infrastructure::paths::db_path();
        let mut conn = rusqlite::Connection::open(&db_path).expect("open test db");
        crate::infrastructure::migration_runner::run_migrations(&mut conn).expect("run migrations");
        conn.execute(
            "INSERT INTO sessions (id, provider, project_path, status, work_status, started_at)
             VALUES (?1, 'codex', '/tmp/project', 'active', 'working', '2026-03-11T05:00:00Z')",
            rusqlite::params![session_id],
        )
        .expect("insert session");
        conn.execute(
            "INSERT INTO subagents (id, session_id, agent_type, transcript_path, started_at)
             VALUES (?1, ?2, 'worker', ?3, '2026-03-11T05:00:00Z')",
            rusqlite::params![
                subagent_id,
                session_id,
                transcript_path.to_string_lossy().to_string()
            ],
        )
        .expect("insert subagent");

        let Json(response) =
            list_subagent_messages_endpoint(Path((session_id.clone(), subagent_id.clone()))).await;

        std::fs::remove_file(&transcript_path).expect("remove transcript");

        assert_eq!(response.session_id, session_id);
        assert_eq!(response.subagent_id, subagent_id);
        assert_eq!(response.messages.len(), 2);
        assert_eq!(response.messages[0].content, "Inspect the auth flow");
        assert_eq!(
            response.messages[1].content,
            "I found the auth coordinator in the runtime layer."
        );
    }
}
