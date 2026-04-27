use codex_protocol::models::{ContentItem, ImageDetail};
use orbitdock_protocol::ImageInput;

pub(super) fn extract_text_from_content(content: &[ContentItem]) -> Option<String> {
  let mut parts = Vec::new();
  for item in content {
    match item {
      ContentItem::InputText { text } | ContentItem::OutputText { text } => {
        let trimmed = text.trim();
        if !trimmed.is_empty() {
          parts.push(trimmed.to_string());
        }
      }
      _ => {}
    }
  }
  if parts.is_empty() {
    None
  } else {
    Some(parts.join("\n"))
  }
}

pub(super) fn extract_images_from_content(content: &[ContentItem]) -> Vec<ImageInput> {
  let mut images = Vec::new();
  for item in content {
    if let ContentItem::InputImage { image_url, detail } = item {
      images.push(ImageInput {
        input_type: "url".to_string(),
        value: image_url.clone(),
        detail: detail.map(image_detail_value),
        ..Default::default()
      });
    }
  }
  images
}

fn image_detail_value(detail: ImageDetail) -> String {
  match detail {
    ImageDetail::Auto => "auto",
    ImageDetail::Low => "low",
    ImageDetail::High => "high",
    ImageDetail::Original => "original",
  }
  .to_string()
}
