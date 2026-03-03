use orbitdock_protocol::WorktreeSummary;
use serde::{Deserialize, Serialize};

use crate::cli::WorktreeAction;
use crate::client::rest::RestClient;
use crate::error::EXIT_SUCCESS;
use crate::output::Output;

#[derive(Debug, Deserialize, Serialize)]
struct WorktreesListResponse {
    repo_root: Option<String>,
    worktrees: Vec<WorktreeSummary>,
}

#[derive(Debug, Deserialize, Serialize)]
struct WorktreeCreatedResponse {
    worktree: WorktreeSummary,
}

#[derive(Debug, Deserialize, Serialize)]
struct WorktreeRemovedResponse {
    worktree_id: String,
    ok: bool,
}

#[derive(Debug, Serialize)]
struct CreateWorktreeRequest {
    repo_path: String,
    branch_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    base_branch: Option<String>,
}

#[derive(Debug, Serialize)]
struct DiscoverWorktreesRequest {
    repo_path: String,
}

pub async fn run(action: &WorktreeAction, rest: &RestClient, output: &Output) -> i32 {
    match action {
        WorktreeAction::List { repo } => list(rest, output, repo.as_deref()).await,
        WorktreeAction::Create { repo, branch, base } => {
            create(rest, output, repo, branch, base.as_deref()).await
        }
        WorktreeAction::Discover { repo } => discover(rest, output, repo).await,
        WorktreeAction::Remove {
            worktree_id,
            force,
            delete_branch,
            delete_remote_branch,
        } => {
            remove(
                rest,
                output,
                worktree_id,
                *force,
                *delete_branch,
                *delete_remote_branch,
            )
            .await
        }
    }
}

async fn list(rest: &RestClient, output: &Output, repo: Option<&str>) -> i32 {
    let path = match repo {
        Some(r) => format!("/api/worktrees?repo_root={}", urlencoding::encode(r)),
        None => "/api/worktrees".to_string(),
    };

    match rest.get::<WorktreesListResponse>(&path).await.into_result() {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else if resp.worktrees.is_empty() {
                println!("No worktrees found.");
            } else {
                for w in &resp.worktrees {
                    let status = w.status.as_str();
                    println!(
                        "  {} ({}) - {} [{}]",
                        w.branch, status, w.worktree_path, w.id
                    );
                }
            }
            EXIT_SUCCESS
        }
        Err((code, err)) => {
            output.print_error(&err);
            code
        }
    }
}

async fn create(
    rest: &RestClient,
    output: &Output,
    repo: &str,
    branch: &str,
    base: Option<&str>,
) -> i32 {
    let body = CreateWorktreeRequest {
        repo_path: repo.to_string(),
        branch_name: branch.to_string(),
        base_branch: base.map(|s| s.to_string()),
    };
    match rest
        .post_json::<_, WorktreeCreatedResponse>("/api/worktrees", &body)
        .await
        .into_result()
    {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else {
                println!(
                    "Created worktree: {} at {}",
                    resp.worktree.branch, resp.worktree.worktree_path
                );
            }
            EXIT_SUCCESS
        }
        Err((code, err)) => {
            output.print_error(&err);
            code
        }
    }
}

async fn discover(rest: &RestClient, output: &Output, repo: &str) -> i32 {
    let body = DiscoverWorktreesRequest {
        repo_path: repo.to_string(),
    };
    match rest
        .post_json::<_, WorktreesListResponse>("/api/worktrees/discover", &body)
        .await
        .into_result()
    {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else {
                println!("Discovered {} worktree(s):", resp.worktrees.len());
                for w in &resp.worktrees {
                    println!("  {} - {}", w.branch, w.worktree_path);
                }
            }
            EXIT_SUCCESS
        }
        Err((code, err)) => {
            output.print_error(&err);
            code
        }
    }
}

async fn remove(
    rest: &RestClient,
    output: &Output,
    worktree_id: &str,
    force: bool,
    delete_branch: bool,
    delete_remote_branch: bool,
) -> i32 {
    let mut query_parts = Vec::new();
    if force {
        query_parts.push("force=true".to_string());
    }
    if delete_branch {
        query_parts.push("delete_branch=true".to_string());
    }
    if delete_remote_branch {
        query_parts.push("delete_remote_branch=true".to_string());
    }

    let path = if query_parts.is_empty() {
        format!("/api/worktrees/{worktree_id}")
    } else {
        format!("/api/worktrees/{worktree_id}?{}", query_parts.join("&"))
    };

    match rest
        .delete::<WorktreeRemovedResponse>(&path)
        .await
        .into_result()
    {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else if resp.ok {
                println!("Worktree {} removed.", worktree_id);
            }
            EXIT_SUCCESS
        }
        Err((code, err)) => {
            output.print_error(&err);
            code
        }
    }
}
