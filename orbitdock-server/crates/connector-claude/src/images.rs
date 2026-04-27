use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use serde_json::Value;

use crate::protocol::{ImageSource, UserContentBlock};

/// Extract an ImageInput from an Anthropic image content block.
///
/// Claude Code JSONL user messages contain image blocks in the Anthropic API
/// format:
/// ```json
/// {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "..."}}
/// {"type": "image", "source": {"type": "url", "url": "https://..."}}
/// ```
pub(crate) fn extract_image_input(block: &Value) -> Option<orbitdock_protocol::ImageInput> {
  let source = block.get("source")?;
  let source_type = source.get("type").and_then(|v| v.as_str())?;

  match source_type {
    "base64" => {
      let media_type = source
        .get("media_type")
        .and_then(|v| v.as_str())
        .unwrap_or("image/png");
      let data = source.get("data").and_then(|v| v.as_str())?;
      let data_uri = format!("data:{};base64,{}", media_type, data);
      let byte_count = (data.len() * 3 / 4) as u64;
      Some(orbitdock_protocol::ImageInput {
        input_type: "url".to_string(),
        value: data_uri,
        mime_type: Some(media_type.to_string()),
        byte_count: Some(byte_count),
        display_name: None,
        pixel_width: None,
        pixel_height: None,
        detail: None,
      })
    }
    "url" => {
      let url = source.get("url").and_then(|v| v.as_str())?;
      Some(orbitdock_protocol::ImageInput {
        input_type: "url".to_string(),
        value: url.to_string(),
        mime_type: None,
        byte_count: None,
        display_name: None,
        pixel_width: None,
        pixel_height: None,
        detail: None,
      })
    }
    _ => None,
  }
}

/// Transform ImageInput to Anthropic's image content block format.
/// - URL images: pass through as-is
/// - Path images: read file, convert to base64
pub(crate) fn transform_image(
  image: &orbitdock_protocol::ImageInput,
) -> Result<UserContentBlock, String> {
  match image.input_type.as_str() {
    "url" => {
      if let Some((media_type, data)) = parse_data_uri_base64(&image.value) {
        Ok(UserContentBlock::Image {
          source: ImageSource::Base64 { media_type, data },
        })
      } else {
        Ok(UserContentBlock::Image {
          source: ImageSource::Url {
            url: image.value.clone(),
          },
        })
      }
    }
    "path" => {
      let bytes = std::fs::read(&image.value)
        .map_err(|e| format!("Failed to read image file {}: {}", image.value, e))?;
      let media_type = infer_media_type(&image.value);
      let data = STANDARD.encode(&bytes);

      Ok(UserContentBlock::Image {
        source: ImageSource::Base64 { media_type, data },
      })
    }
    other => Err(format!("Unknown image input_type: {}", other)),
  }
}

/// Parse a `data:*;base64,...` URI into `(media_type, base64_data)`.
pub(crate) fn parse_data_uri_base64(uri: &str) -> Option<(String, String)> {
  let without_scheme = uri.strip_prefix("data:")?;
  let comma_pos = without_scheme.find(',')?;
  let meta = &without_scheme[..comma_pos];
  if !meta.ends_with(";base64") {
    return None;
  }

  let media_type = &meta[..meta.len() - 7];
  let normalized_media_type = if media_type.is_empty() {
    "image/png"
  } else {
    media_type
  };

  let raw_data = &without_scheme[comma_pos + 1..];
  let normalized_data: String = raw_data
    .chars()
    .filter(|c| !c.is_ascii_whitespace())
    .collect();
  if normalized_data.is_empty() {
    return None;
  }

  Some((normalized_media_type.to_string(), normalized_data))
}

/// Infer MIME type from file path extension.
fn infer_media_type(path: &str) -> String {
  let path_lower = path.to_lowercase();
  if path_lower.ends_with(".png") {
    "image/png".to_string()
  } else if path_lower.ends_with(".jpg") || path_lower.ends_with(".jpeg") {
    "image/jpeg".to_string()
  } else if path_lower.ends_with(".gif") {
    "image/gif".to_string()
  } else if path_lower.ends_with(".webp") {
    "image/webp".to_string()
  } else {
    "image/png".to_string()
  }
}
