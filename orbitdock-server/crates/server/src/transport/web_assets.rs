use axum::{
    body::Body,
    http::{header, HeaderValue, StatusCode, Uri},
    response::Response,
};
use rust_embed::Embed;

#[derive(Embed)]
#[folder = "../../../orbitdock-web/dist"]
struct WebAssets;

/// Serve embedded web assets, falling back to `index.html` for SPA routing.
pub async fn web_asset_handler(uri: Uri) -> Response {
    let path = uri.path().trim_start_matches('/');

    // Try serving the exact file first
    if !path.is_empty() {
        if let Some(response) = serve_file(path) {
            return response;
        }
    }

    // SPA fallback — serve index.html for all non-file routes
    match WebAssets::get("index.html") {
        Some(content) => Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, "text/html; charset=utf-8")
            .header(header::CACHE_CONTROL, "no-cache")
            .body(Body::from(content.data.to_vec()))
            .unwrap(),
        None => Response::builder()
            .status(StatusCode::NOT_FOUND)
            .body(Body::from("web UI not bundled in this build"))
            .unwrap(),
    }
}

fn serve_file(path: &str) -> Option<Response> {
    let asset = WebAssets::get(path)?;

    let mime = mime_guess::from_path(path).first_or_octet_stream();

    // Hashed assets (Vite puts them in /assets/) are immutable
    let cache = if path.starts_with("assets/") {
        "public, max-age=31536000, immutable"
    } else {
        "no-cache"
    };

    Some(
        Response::builder()
            .status(StatusCode::OK)
            .header(
                header::CONTENT_TYPE,
                HeaderValue::from_str(mime.as_ref()).unwrap(),
            )
            .header(header::CACHE_CONTROL, cache)
            .body(Body::from(asset.data.to_vec()))
            .unwrap(),
    )
}

/// Returns `true` when the compiled binary contains at least `index.html`.
pub fn has_web_assets() -> bool {
    WebAssets::get("index.html").is_some()
}
