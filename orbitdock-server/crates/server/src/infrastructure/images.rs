//! Server-managed image attachment storage and transport normalization.
//!
//! Attachments are content-addressed: the SHA-256 hash of the image bytes
//! becomes the attachment ID. Uploading the same image twice is a no-op —
//! the second write is skipped because the file already exists.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use dashmap::DashMap;
use ring::digest;
use tracing::warn;

use orbitdock_protocol::ImageInput;

use crate::infrastructure::paths::images_dir;

/// Cached `fs::metadata` results keyed by absolute path.
/// Stores (file_size, mime_type) to avoid repeated syscalls.
static METADATA_CACHE: OnceLock<DashMap<PathBuf, (u64, Option<&'static str>)>> = OnceLock::new();

fn metadata_cache() -> &'static DashMap<PathBuf, (u64, Option<&'static str>)> {
    METADATA_CACHE.get_or_init(DashMap::new)
}

/// Maximum number of cached metadata entries before eviction.
const METADATA_CACHE_MAX_ENTRIES: usize = 4096;

/// Get cached (byte_count, mime_type) for a path, falling back to fs::metadata.
fn cached_metadata(path: &Path) -> Option<(u64, Option<&'static str>)> {
    let cache = metadata_cache();
    if let Some(entry) = cache.get(path) {
        return Some(*entry.value());
    }
    let meta = fs::metadata(path).ok()?;
    let size = meta.len();
    let mime = mime_type_for_path(path);
    // Evict all entries if cache is too large (simple, avoids unbounded growth)
    if cache.len() >= METADATA_CACHE_MAX_ENTRIES {
        cache.clear();
    }
    cache.insert(path.to_path_buf(), (size, mime));
    Some((size, mime))
}

/// SHA-256 hash → hex string (first 32 hex chars = 16 bytes = 128 bits).
/// Collision-safe for practical image dedup while keeping filenames short.
fn content_hash(bytes: &[u8]) -> String {
    let hash = digest::digest(&digest::SHA256, bytes);
    hash.as_ref()
        .iter()
        .take(16)
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

pub fn store_uploaded_attachment(
    session_id: &str,
    bytes: &[u8],
    mime_type: &str,
    display_name: Option<&str>,
    pixel_width: Option<u32>,
    pixel_height: Option<u32>,
) -> Result<ImageInput, String> {
    let normalized_mime_type = normalize_mime_type(mime_type).unwrap_or("image/png");
    let hash = content_hash(bytes);
    let attachment_id = format!(
        "orbitdock-image-{}.{}",
        hash,
        mime_to_extension(normalized_mime_type)
    );
    let path = attachment_path(session_id, &attachment_id)?;

    // Content-addressed: skip write if the file already exists (same hash = same content).
    if !path.exists() {
        fs::create_dir_all(path.parent().ok_or("missing attachment parent dir")?)
            .map_err(|error| format!("create image dir: {error}"))?;
        fs::write(&path, bytes).map_err(|error| format!("write attachment: {error}"))?;
        // Populate metadata cache for the new file
        metadata_cache().insert(
            path,
            (
                bytes.len() as u64,
                mime_type_for_path(Path::new(&attachment_id)),
            ),
        );
    }

    Ok(ImageInput {
        input_type: "attachment".to_string(),
        value: attachment_id,
        mime_type: Some(normalized_mime_type.to_string()),
        byte_count: Some(bytes.len() as u64),
        display_name: display_name
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned),
        pixel_width,
        pixel_height,
    })
}

pub fn materialize_images_for_message(session_id: &str, images: &[ImageInput]) -> Vec<ImageInput> {
    images
        .iter()
        .map(|image| materialize_image_for_message(session_id, image))
        .collect()
}

pub fn resolve_images_for_connector(session_id: &str, images: &[ImageInput]) -> Vec<ImageInput> {
    images
        .iter()
        .map(|image| resolve_image_for_connector(session_id, image))
        .collect()
}

pub fn read_attachment_bytes(
    session_id: &str,
    attachment_id: &str,
) -> Result<(Vec<u8>, String), String> {
    let path = attachment_path(session_id, attachment_id)?;
    let bytes = fs::read(&path).map_err(|error| format!("read attachment: {error}"))?;
    let mime_type = mime_type_for_path(&path).unwrap_or("image/png").to_string();
    Ok((bytes, mime_type))
}

fn materialize_image_for_message(session_id: &str, image: &ImageInput) -> ImageInput {
    match image.input_type.as_str() {
        "attachment" => enrich_attachment_metadata(session_id, image),
        "path" => {
            managed_attachment_ref_from_path(session_id, image).unwrap_or_else(|| image.clone())
        }
        "url" if image.value.starts_with("data:") => match decode_data_uri_bytes(&image.value) {
            Ok((mime_type, bytes)) => match store_uploaded_attachment(
                session_id,
                &bytes,
                mime_type,
                image.display_name.as_deref(),
                image.pixel_width,
                image.pixel_height,
            ) {
                Ok(stored) => stored,
                Err(error) => {
                    warn!(
                        event = "image.attachment_store_failed",
                        session_id = session_id,
                        error = %error,
                        "Failed to persist inline image as attachment"
                    );
                    image.clone()
                }
            },
            Err(error) => {
                warn!(
                    event = "image.data_uri_decode_failed",
                    session_id = session_id,
                    error = %error,
                    "Failed to decode inline image"
                );
                image.clone()
            }
        },
        _ => image.clone(),
    }
}

fn resolve_image_for_connector(session_id: &str, image: &ImageInput) -> ImageInput {
    match image.input_type.as_str() {
        "attachment" => match attachment_path(session_id, &image.value) {
            Ok(path) => {
                let meta = cached_metadata(&path);
                ImageInput {
                    input_type: "path".to_string(),
                    value: path.to_string_lossy().to_string(),
                    mime_type: image
                        .mime_type
                        .clone()
                        .or_else(|| meta.and_then(|(_, mime)| mime).map(ToOwned::to_owned)),
                    byte_count: image.byte_count.or_else(|| meta.map(|(size, _)| size)),
                    display_name: image.display_name.clone(),
                    pixel_width: image.pixel_width,
                    pixel_height: image.pixel_height,
                }
            }
            Err(error) => {
                warn!(
                    event = "image.attachment_resolve_failed",
                    session_id = session_id,
                    attachment_id = %image.value,
                    error = %error,
                    "Failed to resolve attachment for connector"
                );
                image.clone()
            }
        },
        _ => image.clone(),
    }
}

fn managed_attachment_ref_from_path(session_id: &str, image: &ImageInput) -> Option<ImageInput> {
    let path = PathBuf::from(&image.value);
    let attachment_id = attachment_id_from_managed_path(session_id, &path)?;
    let meta = cached_metadata(&path);
    Some(ImageInput {
        input_type: "attachment".to_string(),
        value: attachment_id.to_string(),
        mime_type: image
            .mime_type
            .clone()
            .or_else(|| meta.and_then(|(_, mime)| mime).map(ToOwned::to_owned)),
        byte_count: image.byte_count.or_else(|| meta.map(|(size, _)| size)),
        display_name: image.display_name.clone(),
        pixel_width: image.pixel_width,
        pixel_height: image.pixel_height,
    })
}

fn enrich_attachment_metadata(session_id: &str, image: &ImageInput) -> ImageInput {
    let Ok(path) = attachment_path(session_id, &image.value) else {
        return image.clone();
    };
    let meta = cached_metadata(&path);
    ImageInput {
        input_type: "attachment".to_string(),
        value: image.value.clone(),
        mime_type: image
            .mime_type
            .clone()
            .or_else(|| meta.and_then(|(_, mime)| mime).map(ToOwned::to_owned)),
        byte_count: image.byte_count.or_else(|| meta.map(|(size, _)| size)),
        display_name: image.display_name.clone(),
        pixel_width: image.pixel_width,
        pixel_height: image.pixel_height,
    }
}

fn decode_data_uri_bytes(data_uri: &str) -> Result<(&str, Vec<u8>), String> {
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
    let mime_type = normalize_mime_type(&meta[..meta.len() - 7]).unwrap_or("image/png");
    let bytes = STANDARD
        .decode(base64_data)
        .map_err(|error| format!("base64 decode: {error}"))?;
    Ok((mime_type, bytes))
}

fn attachment_path(session_id: &str, attachment_id: &str) -> Result<PathBuf, String> {
    let attachment_id = validate_attachment_id(attachment_id)?;
    Ok(images_dir()
        .join(safe_component(session_id))
        .join(attachment_id))
}

fn validate_attachment_id(attachment_id: &str) -> Result<&str, String> {
    let trimmed = attachment_id.trim();
    if trimmed.is_empty()
        || trimmed.contains('/')
        || trimmed.contains('\\')
        || trimmed == "."
        || trimmed == ".."
    {
        return Err("invalid attachment id".into());
    }
    Ok(trimmed)
}

fn attachment_id_from_managed_path<'a>(session_id: &str, path: &'a Path) -> Option<&'a str> {
    let managed_dir = images_dir().join(safe_component(session_id));
    let file_name = path.file_name()?.to_str()?;
    if path.starts_with(&managed_dir) {
        Some(file_name)
    } else {
        None
    }
}

fn safe_component(value: &str) -> String {
    value
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || character == '-' || character == '_' {
                character
            } else {
                '_'
            }
        })
        .collect()
}

fn normalize_mime_type(value: &str) -> Option<&str> {
    value
        .split(';')
        .next()
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

fn mime_to_extension(mime_type: &str) -> &str {
    match mime_type {
        "image/png" => "png",
        "image/jpeg" => "jpg",
        "image/gif" => "gif",
        "image/webp" => "webp",
        "image/heic" => "heic",
        "image/heif" => "heif",
        "image/svg+xml" => "svg",
        "image/bmp" => "bmp",
        "image/tiff" => "tiff",
        _ => "png",
    }
}

fn mime_type_for_path(path: &Path) -> Option<&'static str> {
    let ext = path
        .extension()
        .and_then(|value| value.to_str())
        .map(|value| value.to_ascii_lowercase())?;
    match ext.as_str() {
        "png" => Some("image/png"),
        "jpg" | "jpeg" => Some("image/jpeg"),
        "gif" => Some("image/gif"),
        "webp" => Some("image/webp"),
        "heic" => Some("image/heic"),
        "heif" => Some("image/heif"),
        "svg" => Some("image/svg+xml"),
        "bmp" => Some("image/bmp"),
        "tiff" | "tif" => Some("image/tiff"),
        _ => None,
    }
}
