use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use anyhow::Context;
use orbitdock_connector_codex::rollout_parser::PersistedFileState;

#[derive(Debug, Clone)]
pub(crate) struct JsonlTailState {
    pub(crate) offset: u64,
    pub(crate) tail: String,
    pub(crate) session_id: Option<String>,
    pub(crate) project_path: Option<String>,
    pub(crate) model_provider: Option<String>,
    pub(crate) ignore_existing: bool,
    pub(crate) is_active: bool,
    pub(crate) last_seen_activity: SystemTime,
}

pub(crate) struct JsonlTailer {
    watcher_started_at: SystemTime,
    checkpoint_seeds: HashMap<String, PersistedFileState>,
    states: HashMap<String, JsonlTailState>,
}

impl JsonlTailer {
    pub(crate) fn new(checkpoint_seeds: HashMap<String, PersistedFileState>) -> Self {
        Self {
            watcher_started_at: SystemTime::now(),
            checkpoint_seeds,
            states: HashMap::new(),
        }
    }

    pub(crate) fn mark_active(&mut self, path: &str) {
        if let Some(state) = self.states.get_mut(path) {
            state.is_active = true;
            state.last_seen_activity = SystemTime::now();
            return;
        }

        self.states.insert(
            path.to_string(),
            JsonlTailState {
                offset: 0,
                tail: String::new(),
                session_id: None,
                project_path: None,
                model_provider: None,
                ignore_existing: false,
                is_active: true,
                last_seen_activity: SystemTime::now(),
            },
        );
    }

    pub(crate) fn ensure_file(
        &mut self,
        path: &str,
        size: u64,
        created_at: Option<SystemTime>,
    ) {
        if let Some(state) = self.states.get_mut(path) {
            if state.session_id.is_some() || state.project_path.is_some() || state.model_provider.is_some()
            {
                return;
            }

            if let Some(seed) = self.checkpoint_seeds.get(path) {
                state.offset = seed.offset;
                state.session_id = seed.session_id.clone();
                state.project_path = seed.project_path.clone();
                state.model_provider = seed.model_provider.clone();
                state.ignore_existing = seed.ignore_existing.unwrap_or(false);
                return;
            }

            if let Some(created_at) = created_at {
                if created_at < self.watcher_started_at {
                    state.ignore_existing = true;
                    state.offset = size;
                }
            }
            return;
        }

        if let Some(seed) = self.checkpoint_seeds.get(path) {
            self.states.insert(
                path.to_string(),
                JsonlTailState {
                    offset: seed.offset,
                    tail: String::new(),
                    session_id: seed.session_id.clone(),
                    project_path: seed.project_path.clone(),
                    model_provider: seed.model_provider.clone(),
                    ignore_existing: seed.ignore_existing.unwrap_or(false),
                    is_active: false,
                    last_seen_activity: SystemTime::now(),
                },
            );
            return;
        }

        let mut ignore_existing = false;
        let mut offset = 0;
        if let Some(created_at) = created_at {
            if created_at < self.watcher_started_at {
                ignore_existing = true;
                offset = size;
            }
        }

        self.states.insert(
            path.to_string(),
            JsonlTailState {
                offset,
                tail: String::new(),
                session_id: None,
                project_path: None,
                model_provider: None,
                ignore_existing,
                is_active: false,
                last_seen_activity: SystemTime::now(),
            },
        );
    }

    pub(crate) fn binding_session_id(&self, path: &str) -> Option<String> {
        self.states.get(path).and_then(|state| state.session_id.clone())
    }

    pub(crate) fn apply_binding(&mut self, path: &str, binding: &PersistedFileState) {
        if let Some(state) = self.states.get_mut(path) {
            state.session_id = binding.session_id.clone();
            state.project_path = binding.project_path.clone();
            state.model_provider = binding.model_provider.clone();
        }
    }

    pub(crate) fn reset_binding(&mut self, path: &str) {
        if let Some(state) = self.states.get_mut(path) {
            state.session_id = None;
            state.project_path = None;
            state.model_provider = None;
        }
    }

    pub(crate) fn remove_path(&mut self, path: &str) {
        self.states.remove(path);
    }

    pub(crate) fn checkpoint_snapshot(&self, path: &str) -> Option<PersistedFileState> {
        self.states.get(path).map(|state| PersistedFileState {
            offset: state.offset,
            session_id: state.session_id.clone(),
            project_path: state.project_path.clone(),
            model_provider: state.model_provider.clone(),
            ignore_existing: Some(state.ignore_existing),
        })
    }

    pub(crate) fn active_candidates(&mut self, within_secs: u64) -> Vec<PathBuf> {
        let now = SystemTime::now();
        self.states.retain(|path, state| {
            let is_recent = now
                .duration_since(state.last_seen_activity)
                .unwrap_or_default()
                .as_secs()
                <= within_secs;
            state.is_active && is_recent && Path::new(path).exists()
        });

        self.states
            .iter()
            .filter_map(|(path, state)| {
                let path_buf = PathBuf::from(path);
                let metadata = fs::metadata(&path_buf).ok()?;
                (metadata.len() != state.offset).then_some(path_buf)
            })
            .collect()
    }

    pub(crate) fn read_first_line(&self, path: &Path) -> anyhow::Result<Option<String>> {
        let file = match fs::File::open(path) {
            Ok(file) => file,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(err) => return Err(err.into()),
        };

        let mut reader = std::io::BufReader::new(file);
        let mut line = String::new();
        let read = std::io::BufRead::read_line(&mut reader, &mut line)?;
        if read == 0 {
            return Ok(None);
        }

        Ok(Some(line.trim_end_matches(['\r', '\n']).to_string()))
    }

    pub(crate) fn read_appended_lines(&mut self, path: &Path) -> anyhow::Result<Vec<String>> {
        let path_string = path.to_string_lossy().to_string();
        let metadata = fs::metadata(path)?;
        let size = metadata.len();
        let created_at = metadata.created().ok();
        self.ensure_file(&path_string, size, created_at);

        let Some(state) = self.states.get_mut(&path_string) else {
            return Ok(Vec::new());
        };

        if state.ignore_existing {
            if size > state.offset {
                state.ignore_existing = false;
            } else {
                state.offset = size;
                return Ok(Vec::new());
            }
        }

        if size < state.offset {
            state.offset = 0;
            state.tail.clear();
        }

        if size == state.offset {
            return Ok(Vec::new());
        }

        let chunk = read_file_chunk(path, state.offset)?;
        state.offset = size;
        if chunk.is_empty() {
            return Ok(Vec::new());
        }

        let chunk = String::from_utf8_lossy(&chunk).to_string();
        if chunk.is_empty() {
            return Ok(Vec::new());
        }

        let combined = format!("{}{}", state.tail, chunk);
        let mut parts: Vec<&str> = combined.split('\n').collect();
        state.tail = parts.pop().unwrap_or_default().to_string();

        Ok(parts
            .into_iter()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(ToOwned::to_owned)
            .collect())
    }
}

fn read_file_chunk(path: &Path, offset: u64) -> anyhow::Result<Vec<u8>> {
    let mut file = OpenOptions::new()
        .read(true)
        .open(path)
        .with_context(|| format!("open {}", path.display()))?;
    file.seek(SeekFrom::Start(offset))?;
    let mut buf = Vec::new();
    file.read_to_end(&mut buf)?;
    Ok(buf)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn read_appended_lines_buffers_partial_line_until_completed() {
        let tmp_dir =
            std::env::temp_dir().join(format!("orbitdock-jsonl-tailer-partial-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp_dir);
        std::fs::create_dir_all(&tmp_dir).expect("create temp dir");
        let path = tmp_dir.join("rollout.jsonl");
        let mut tailer = JsonlTailer::new(HashMap::new());
        std::fs::write(&path, b"{\"type\":\"session_meta\"").expect("write partial line");
        let lines = tailer
            .read_appended_lines(&path)
            .expect("read initial partial line");
        assert!(lines.is_empty(), "partial line should stay buffered");

        std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .expect("reopen rollout file")
            .write_all(b"}\n")
            .expect("complete line");

        let lines = tailer
            .read_appended_lines(&path)
            .expect("read completed line");
        assert_eq!(lines, vec!["{\"type\":\"session_meta\"}".to_string()]);

        let _ = std::fs::remove_dir_all(&tmp_dir);
    }

    #[test]
    fn checkpoint_seed_resumes_from_stored_offset() {
        let tmp_dir =
            std::env::temp_dir().join(format!("orbitdock-jsonl-tailer-resume-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp_dir);
        std::fs::create_dir_all(&tmp_dir).expect("create temp dir");
        let path = tmp_dir.join("rollout.jsonl");
        std::fs::write(
            &path,
            b"{\"type\":\"session_meta\"}\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\"}}\n",
        )
        .expect("write rollout file");

        let first_line_len = "{\"type\":\"session_meta\"}\n".len() as u64;
        let mut tailer = JsonlTailer::new(HashMap::from([(
            path.to_string_lossy().to_string(),
            PersistedFileState {
                offset: first_line_len,
                session_id: Some("session-1".to_string()),
                project_path: Some("/tmp/repo".to_string()),
                model_provider: Some("codex".to_string()),
                ignore_existing: Some(false),
            },
        )]));

        let lines = tailer
            .read_appended_lines(&path)
            .expect("read from stored offset");
        assert_eq!(
            lines,
            vec!["{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\"}}".to_string()]
        );

        let checkpoint = tailer
            .checkpoint_snapshot(path.to_string_lossy().as_ref())
            .expect("checkpoint snapshot");
        assert_eq!(
            checkpoint.offset,
            std::fs::metadata(&path).expect("stat rollout").len()
        );

        let _ = std::fs::remove_dir_all(&tmp_dir);
    }
}
