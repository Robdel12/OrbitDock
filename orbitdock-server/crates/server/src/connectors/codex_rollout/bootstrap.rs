use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use orbitdock_connector_codex::rollout_parser::{
    collect_jsonl_files, is_jsonl_path, is_recent_file, load_persisted_state,
    matches_supported_event_kind, RolloutFileProcessor, CATCHUP_SWEEP_SECS,
    STARTUP_SEED_RECENT_SECS,
};
use tokio::sync::mpsc;
use tracing::{info, warn};

use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_registry::SessionRegistry;

use super::runtime::{WatcherMessage, WatcherRuntime};

pub async fn start_rollout_watcher(
    app_state: Arc<SessionRegistry>,
    persist_tx: mpsc::Sender<PersistCommand>,
) -> anyhow::Result<()> {
    if std::env::var("ORBITDOCK_DISABLE_CODEX_WATCHER").as_deref() == Ok("1") {
        info!(
            component = "rollout_watcher",
            event = "rollout_watcher.disabled",
            "Rollout watcher disabled by ORBITDOCK_DISABLE_CODEX_WATCHER"
        );
        return Ok(());
    }

    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let sessions_dir = PathBuf::from(&home).join(".codex/sessions");
    if !sessions_dir.exists() {
        info!(
            component = "rollout_watcher",
            event = "rollout_watcher.sessions_dir_missing",
            path = %sessions_dir.display(),
            "Rollout sessions directory missing"
        );
        return Ok(());
    }

    let state_path = crate::infrastructure::paths::rollout_state_path();
    let persisted_state = load_persisted_state(&state_path);

    let (tx, mut rx) = mpsc::unbounded_channel::<WatcherMessage>();
    let watcher_tx = tx.clone();

    let mut watcher = RecommendedWatcher::new(
        move |res: Result<notify::Event, notify::Error>| match res {
            Ok(event) => {
                if !matches_supported_event_kind(&event.kind) {
                    return;
                }
                for path in event.paths {
                    let _ = watcher_tx.send(WatcherMessage::FsEvent(path));
                }
            }
            Err(err) => {
                warn!(
                    component = "rollout_watcher",
                    event = "rollout_watcher.fs_event_error",
                    error = %err,
                    "Rollout watcher event error"
                );
            }
        },
        notify::Config::default(),
    )?;

    watcher.watch(&sessions_dir, RecursiveMode::Recursive)?;

    info!(
        component = "rollout_watcher",
        event = "rollout_watcher.started",
        path = %sessions_dir.display(),
        "Rollout watcher started"
    );

    let processor = RolloutFileProcessor::new(state_path, persisted_state);

    let mut runtime = WatcherRuntime {
        app_state,
        persist_tx,
        tx,
        processor,
        debounce_tasks: HashMap::new(),
        session_timeouts: HashMap::new(),
    };

    let existing_files = collect_jsonl_files(&sessions_dir);
    let mut seeded = 0usize;
    for path in &existing_files {
        if let Ok(metadata) = std::fs::metadata(path) {
            runtime.processor.ensure_file_state(
                path.to_string_lossy().as_ref(),
                metadata.len(),
                metadata.created().ok(),
            );
        }

        if is_recent_file(path, STARTUP_SEED_RECENT_SECS) {
            let path_string = path.to_string_lossy().to_string();
            match runtime.processor.ensure_session_meta(&path_string).await {
                Ok(events) => {
                    if let Err(err) = runtime.handle_rollout_events(events).await {
                        warn!(
                            component = "rollout_watcher",
                            event = "rollout_watcher.seed_event_failed",
                            path = %path.display(),
                            error = %err,
                            "Startup seed event handling failed"
                        );
                    }
                    seeded += 1;
                }
                Err(err) => {
                    warn!(
                        component = "rollout_watcher",
                        event = "rollout_watcher.seed_failed",
                        path = %path.display(),
                        error = %err,
                        "Startup session_meta seed failed"
                    );
                }
            }
        }
    }
    info!(
        component = "rollout_watcher",
        event = "rollout_watcher.seed_complete",
        seeded_files = seeded,
        total_files = existing_files.len(),
        "Rollout startup seed complete"
    );

    let sweep_tx = runtime.tx.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(CATCHUP_SWEEP_SECS)).await;
            if sweep_tx.send(WatcherMessage::Sweep).is_err() {
                break;
            }
        }
    });

    while let Some(msg) = rx.recv().await {
        match msg {
            WatcherMessage::FsEvent(path) => {
                if is_jsonl_path(&path) {
                    runtime.schedule_file(path);
                } else if path.is_dir() {
                    for child in collect_jsonl_files(&path) {
                        runtime.schedule_file(child);
                    }
                } else if let Some(parent) = path.parent() {
                    for child in collect_jsonl_files(parent) {
                        runtime.schedule_file(child);
                    }
                }
            }
            WatcherMessage::ProcessFile(path) => {
                if let Err(err) = runtime.process_file(path).await {
                    warn!(
                        component = "rollout_watcher",
                        event = "rollout_watcher.process_file_failed",
                        error = %err,
                        "Failed processing rollout file"
                    );
                }
            }
            WatcherMessage::SessionTimeout(session_id) => {
                runtime.handle_session_timeout(session_id).await;
            }
            WatcherMessage::Sweep => {
                if let Err(err) = runtime.sweep_files().await {
                    warn!(
                        component = "rollout_watcher",
                        event = "rollout_watcher.sweep_failed",
                        error = %err,
                        "Catch-up sweep failed"
                    );
                }
            }
        }
    }

    drop(watcher);
    Ok(())
}
