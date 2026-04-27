use super::*;

#[tokio::test]
async fn api_paths_never_fall_back_to_html() {
  let response = web_asset_handler(Uri::from_static("/api/sessions/active")).await;

  assert_eq!(response.status(), StatusCode::NOT_FOUND);
  assert_eq!(
    response.headers().get(header::CONTENT_TYPE),
    Some(&HeaderValue::from_static("application/json"))
  );
}

#[tokio::test]
async fn websocket_paths_never_fall_back_to_html() {
  let response = web_asset_handler(Uri::from_static("/ws")).await;

  assert_eq!(response.status(), StatusCode::NOT_FOUND);
  assert_eq!(
    response.headers().get(header::CONTENT_TYPE),
    Some(&HeaderValue::from_static("application/json"))
  );
}
