use super::extract_url;

#[test]
fn extract_url_finds_trycloudflare_url() {
  let line =
    "2024-01-15T12:00:00Z INF +-----------------------------------------------------------+";
  assert_eq!(extract_url(line), None);

  let line = "2024-01-15T12:00:00Z INF |  https://abc-def.trycloudflare.com  |";
  assert_eq!(
    extract_url(line),
    Some("https://abc-def.trycloudflare.com".to_string())
  );
}

#[test]
fn extract_url_handles_no_url() {
  assert_eq!(extract_url("just some text with no url"), None);
}

#[test]
fn extract_url_ignores_cloudflare_terms_links() {
  let line =
    "2024-01-15T12:00:00Z INF If you'd like to learn more, visit https://www.cloudflare.com/website-terms/ for details";
  assert_eq!(extract_url(line), None);
}

#[test]
fn extract_url_prefers_tunnel_hosts() {
  let line = "2024-01-15T12:00:00Z INF tunnel is ready at https://abc-def.trycloudflare.com";
  assert_eq!(
    extract_url(line),
    Some("https://abc-def.trycloudflare.com".to_string())
  );
}
