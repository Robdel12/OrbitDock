use super::*;
use std::path::PathBuf;

use codex_core::config::find_codex_home;
use orbitdock_protocol::conversation_contracts::ConversationRowEntry;
use orbitdock_protocol::{DirectoryEntry, RecentProject, SubagentTool};
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
    pub rows: Vec<ConversationRowEntry>,
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
    let rows = load_subagent_rows(&subagent_id).await;
    Json(SubagentMessagesResponse {
        session_id,
        subagent_id,
        rows,
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

async fn load_subagent_rows(subagent_id: &str) -> Vec<ConversationRowEntry> {
    let Some(path) = resolve_subagent_transcript_path(subagent_id).await else {
        return vec![];
    };

    match load_messages_from_transcript_path(&path, subagent_id).await {
        Ok(rows) => rows,
        Err(err) => {
            warn!(
                component = "api",
                event = "api.subagent_messages.load_error",
                subagent_id = %subagent_id,
                transcript_path = %path,
                error = %err,
                "Failed to load subagent transcript rows"
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
