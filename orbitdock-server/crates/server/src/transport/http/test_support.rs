use std::path::PathBuf;
use std::sync::Arc;

use axum::body::Bytes;
use axum::extract::{Path, Query, State};
use axum::http::{header::CONTENT_TYPE, HeaderMap, HeaderValue};
use axum::Json;
use orbitdock_protocol::ImageInput;
use tokio::sync::mpsc;

use crate::infrastructure::persistence::{flush_batch_for_test, PersistCommand};
use crate::runtime::session_registry::SessionRegistry;
use crate::support::test_support::{ensure_server_test_data_dir, new_test_session_registry};
use crate::transport::http::session_actions::{
    upload_session_image_attachment, UploadImageAttachmentQuery,
};

pub(crate) fn new_test_state(is_primary: bool) -> Arc<SessionRegistry> {
    new_test_session_registry(is_primary)
}

pub(crate) fn ensure_test_db() -> PathBuf {
    ensure_server_test_data_dir();
    let db_path = crate::infrastructure::paths::db_path();
    let mut conn = rusqlite::Connection::open(&db_path).expect("open test db");
    crate::infrastructure::migration_runner::run_migrations(&mut conn)
        .expect("run test migrations");
    db_path
}

pub(crate) fn new_persist_test_state(
    is_primary: bool,
) -> (
    Arc<SessionRegistry>,
    mpsc::Receiver<PersistCommand>,
    PathBuf,
) {
    let db_path = ensure_test_db();
    let (persist_tx, persist_rx) = mpsc::channel(32);
    (
        Arc::new(SessionRegistry::new_with_primary(persist_tx, is_primary)),
        persist_rx,
        db_path,
    )
}

pub(crate) async fn flush_next_persist_command(
    persist_rx: &mut mpsc::Receiver<PersistCommand>,
    db_path: &PathBuf,
) {
    let command = persist_rx
        .recv()
        .await
        .expect("endpoint should enqueue a persistence command");
    flush_batch_for_test(db_path, vec![command]).expect("flush persisted command");
}

pub(crate) async fn upload_test_attachment(
    state: Arc<SessionRegistry>,
    session_id: &str,
    bytes: &'static [u8],
) -> ImageInput {
    let mut headers = HeaderMap::new();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("image/png"));
    let Json(response) = upload_session_image_attachment(
        Path(session_id.to_string()),
        State(state),
        Query(UploadImageAttachmentQuery {
            display_name: Some("test.png".to_string()),
            pixel_width: Some(320),
            pixel_height: Some(200),
        }),
        headers,
        Bytes::from_static(bytes),
    )
    .await
    .expect("upload attachment should succeed");
    response.image
}
