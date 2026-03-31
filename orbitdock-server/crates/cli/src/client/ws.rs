use std::time::Duration;

use anyhow::{bail, Context, Result};
use futures::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message as WsMessage;

use orbitdock_protocol::{
  ClientMessage, ServerHello, ServerMessage, SessionSurface, HTTP_HEADER_CLIENT_VERSION,
  HTTP_HEADER_MINIMUM_SERVER_VERSION,
};

use crate::client::config::ClientConfig;

type WsStream =
  tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

pub struct WsClient {
  write: futures::stream::SplitSink<WsStream, WsMessage>,
  read: futures::stream::SplitStream<WsStream>,
}

impl WsClient {
  /// Connect to the server's WebSocket endpoint.
  pub async fn connect(config: &ClientConfig) -> Result<Self> {
    let ws_url = config
      .server_url
      .replace("http://", "ws://")
      .replace("https://", "wss://");
    let url = format!("{ws_url}/ws");

    let mut request = url
      .into_client_request()
      .context("Failed to build WebSocket request")?;

    if let Some(token) = &config.token {
      request.headers_mut().insert(
        "Authorization",
        format!("Bearer {token}")
          .parse()
          .context("Invalid auth token")?,
      );
    }
    request.headers_mut().insert(
      HTTP_HEADER_CLIENT_VERSION,
      env!("CARGO_PKG_VERSION")
        .parse()
        .context("Invalid client version header")?,
    );
    request.headers_mut().insert(
      HTTP_HEADER_MINIMUM_SERVER_VERSION,
      env!("CARGO_PKG_VERSION")
        .parse()
        .context("Invalid minimum server version header")?,
    );

    let (ws_stream, _) = tokio_tungstenite::connect_async(request)
      .await
      .context("Failed to connect to WebSocket")?;

    let (write, read) = ws_stream.split();
    let mut client = Self { write, read };

    let hello = client
      .recv()
      .await?
      .ok_or_else(|| anyhow::anyhow!("WebSocket closed before hello"))?;
    match hello {
      ServerMessage::Hello { hello } => validate_hello(&hello)?,
      other => bail!("Expected hello from server, received {other:?}"),
    }

    let _ = client.recv().await?;

    Ok(client)
  }

  /// Send a client message.
  pub async fn send(&mut self, msg: &ClientMessage) -> Result<()> {
    let json = serde_json::to_string(msg)?;
    self
      .write
      .send(WsMessage::Text(json.into()))
      .await
      .context("Failed to send message")?;
    Ok(())
  }

  /// Receive the next server message. Returns None on connection close.
  pub async fn recv(&mut self) -> Result<Option<ServerMessage>> {
    loop {
      match self.read.next().await {
        Some(Ok(WsMessage::Text(text))) => {
          let msg: ServerMessage = serde_json::from_str(&text)
            .with_context(|| format!("Failed to parse server message: {text}"))?;
          return Ok(Some(msg));
        }
        Some(Ok(WsMessage::Close(_))) | None => return Ok(None),
        Some(Ok(_)) => continue,
        Some(Err(e)) => bail!("WebSocket error: {e}"),
      }
    }
  }

  /// Receive with a timeout. Returns None on timeout or connection close.
  pub async fn recv_timeout(&mut self, timeout: Duration) -> Result<Option<ServerMessage>> {
    match tokio::time::timeout(timeout, self.recv()).await {
      Ok(result) => result,
      Err(_) => Ok(None),
    }
  }

  /// Subscribe to a session surface. WS now only carries realtime updates;
  /// bootstrap state should come from HTTP.
  pub async fn subscribe_session_surface(
    &mut self,
    session_id: &str,
    surface: SessionSurface,
    since_revision: Option<u64>,
  ) -> Result<()> {
    self
      .send(&ClientMessage::SubscribeSessionSurface {
        session_id: session_id.to_string(),
        surface,
        since_revision,
      })
      .await
  }

  /// Subscribe to the default detail surface.
  pub async fn subscribe_session(&mut self, session_id: &str) -> Result<()> {
    self
      .subscribe_session_surface(session_id, SessionSurface::Detail, None)
      .await
  }
}

fn validate_hello(hello: &ServerHello) -> Result<()> {
  let client_version = env!("CARGO_PKG_VERSION");
  if !version_at_least(&hello.server_version, env!("CARGO_PKG_VERSION")) {
    bail!(
      "Update the OrbitDock server to version {} or later (current: {}).",
      env!("CARGO_PKG_VERSION"),
      hello.server_version
    );
  }

  if !version_at_least(client_version, &hello.minimum_client_version) {
    bail!(
      "Update OrbitDock to version {} or later (current: {}).",
      hello.minimum_client_version,
      client_version
    );
  }

  Ok(())
}

fn version_at_least(left: &str, right: &str) -> bool {
  match (parse_version(left), parse_version(right)) {
    (Some(left), Some(right)) => left >= right,
    _ => false,
  }
}

fn parse_version(value: &str) -> Option<(u64, u64, u64)> {
  let mut parts = value.trim().split('.');
  let major = parts.next()?.parse().ok()?;
  let minor = parts.next().unwrap_or("0").parse().ok()?;
  let patch = parts
    .next()
    .unwrap_or("0")
    .split('-')
    .next()?
    .parse()
    .ok()?;
  Some((major, minor, patch))
}
