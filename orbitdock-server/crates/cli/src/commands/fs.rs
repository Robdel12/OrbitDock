use orbitdock_protocol::{DirectoryEntry, RecentProject};
use serde::{Deserialize, Serialize};

use crate::cli::FsAction;
use crate::client::rest::RestClient;
use crate::error::EXIT_SUCCESS;
use crate::output::Output;

#[derive(Debug, Deserialize, Serialize)]
struct DirectoryListingResponse {
    path: String,
    entries: Vec<DirectoryEntry>,
}

#[derive(Debug, Deserialize, Serialize)]
struct RecentProjectsResponse {
    projects: Vec<RecentProject>,
}

pub async fn run(action: &FsAction, rest: &RestClient, output: &Output) -> i32 {
    match action {
        FsAction::Browse { path } => browse(rest, output, path.as_deref()).await,
        FsAction::Recent => recent(rest, output).await,
    }
}

async fn browse(rest: &RestClient, output: &Output, path: Option<&str>) -> i32 {
    let api_path = match path {
        Some(p) => format!("/api/fs/browse?path={}", urlencoding(p)),
        None => "/api/fs/browse".to_string(),
    };

    match rest
        .get::<DirectoryListingResponse>(&api_path)
        .await
        .into_result()
    {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else {
                println!("{}:", resp.path);
                for entry in &resp.entries {
                    let icon = if entry.is_git {
                        " [git]"
                    } else if entry.is_dir {
                        "/"
                    } else {
                        ""
                    };
                    println!("  {}{}", entry.name, icon);
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

async fn recent(rest: &RestClient, output: &Output) -> i32 {
    match rest
        .get::<RecentProjectsResponse>("/api/fs/recent-projects")
        .await
        .into_result()
    {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else if resp.projects.is_empty() {
                println!("No recent projects.");
            } else {
                println!("Recent projects:");
                for p in &resp.projects {
                    println!("  {}", p.path);
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

fn urlencoding(s: &str) -> String {
    s.replace('%', "%25")
        .replace(' ', "%20")
        .replace('&', "%26")
        .replace('=', "%3D")
        .replace('#', "%23")
}
