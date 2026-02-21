//! Image extraction — writes data-URI images to disk, returns path-based references.

use std::fs;
use std::path::PathBuf;

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use tracing::warn;

use orbitdock_protocol::ImageInput;

use crate::paths::images_dir;

/// If `image` is a data URI, decode it to disk and return a path-based `ImageInput`.
/// Already-path images and failures are returned unchanged (graceful degradation).
pub fn extract_image_to_disk(
    image: &ImageInput,
    session_id: &str,
    message_id: &str,
    index: usize,
) -> ImageInput {
    if image.input_type == "path" {
        return image.clone();
    }

    // Only handle data URIs
    if !image.value.starts_with("data:") {
        return image.clone();
    }

    match write_data_uri_to_disk(&image.value, session_id, message_id, index) {
        Ok(path) => ImageInput {
            input_type: "path".to_string(),
            value: path.to_string_lossy().to_string(),
        },
        Err(e) => {
            warn!(
                event = "image.extract_failed",
                session_id = session_id,
                error = %e,
                "Failed to extract image to disk, keeping original"
            );
            image.clone()
        }
    }
}

/// Extract images from a vec, returning a new vec with path-based references.
pub fn extract_images_to_disk(
    images: &[ImageInput],
    session_id: &str,
    message_id: &str,
) -> Vec<ImageInput> {
    images
        .iter()
        .enumerate()
        .map(|(i, img)| extract_image_to_disk(img, session_id, message_id, i))
        .collect()
}

fn write_data_uri_to_disk(
    data_uri: &str,
    session_id: &str,
    message_id: &str,
    index: usize,
) -> Result<PathBuf, String> {
    // Parse: "data:image/png;base64,{data}"
    let without_scheme = data_uri
        .strip_prefix("data:")
        .ok_or("missing data: prefix")?;

    let comma_pos = without_scheme
        .find(',')
        .ok_or("missing comma in data URI")?;

    let meta = &without_scheme[..comma_pos];
    let base64_data = &without_scheme[comma_pos + 1..];

    if !meta.ends_with(";base64") {
        return Err("not a base64 data URI".into());
    }

    let mime_type = &meta[..meta.len() - 7]; // strip ";base64"
    let ext = mime_to_extension(mime_type);

    // Decode
    let bytes = STANDARD
        .decode(base64_data)
        .map_err(|e| format!("base64 decode: {e}"))?;

    // Sanitize session_id for filesystem (replace non-alphanumeric except dash/underscore)
    let safe_session: String = session_id
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
        .collect();

    let safe_msg: String = message_id
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
        .collect();

    let dir = images_dir().join(&safe_session);
    fs::create_dir_all(&dir).map_err(|e| format!("create dir: {e}"))?;

    let filename = format!("{safe_msg}_{index}.{ext}");
    let path = dir.join(&filename);

    // Skip if already extracted (idempotent)
    if path.exists() {
        return Ok(path);
    }

    fs::write(&path, &bytes).map_err(|e| format!("write file: {e}"))?;

    Ok(path)
}

fn mime_to_extension(mime: &str) -> &str {
    match mime {
        "image/png" => "png",
        "image/jpeg" => "jpg",
        "image/gif" => "gif",
        "image/webp" => "webp",
        "image/svg+xml" => "svg",
        "image/bmp" => "bmp",
        "image/tiff" => "tiff",
        _ => "png",
    }
}
