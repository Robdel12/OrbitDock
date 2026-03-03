use std::time::Duration;

use anyhow::{bail, Context, Result};
use futures::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message as WsMessage;

use orbitdock_protocol::{ClientMessage, ServerMessage, SessionState, SessionSummary};

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

        let (ws_stream, _) = tokio_tungstenite::connect_async(request)
            .await
            .context("Failed to connect to WebSocket")?;

        let (write, read) = ws_stream.split();
        let mut client = Self { write, read };

        // Server sends server_info immediately after connect — consume it
        let _ = client.recv().await?;

        Ok(client)
    }

    /// Send a client message.
    pub async fn send(&mut self, msg: &ClientMessage) -> Result<()> {
        let json = serde_json::to_string(msg)?;
        self.write
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

    /// Subscribe to a session and return its snapshot.
    pub async fn subscribe_session(&mut self, session_id: &str) -> Result<SessionState> {
        self.send(&ClientMessage::SubscribeSession {
            session_id: session_id.to_string(),
            since_revision: None,
            include_snapshot: true,
        })
        .await?;

        loop {
            match self.recv().await? {
                Some(ServerMessage::SessionSnapshot { session }) => return Ok(session),
                Some(ServerMessage::Error { code, message, .. }) => {
                    bail!("[{code}] {message}");
                }
                Some(_) => continue,
                None => bail!("Connection closed before receiving snapshot"),
            }
        }
    }

    /// Subscribe to the sessions list.
    #[allow(dead_code)]
    pub async fn subscribe_list(&mut self) -> Result<Vec<SessionSummary>> {
        self.send(&ClientMessage::SubscribeList).await?;

        loop {
            match self.recv().await? {
                Some(ServerMessage::SessionsList { sessions }) => return Ok(sessions),
                Some(ServerMessage::Error { code, message, .. }) => {
                    bail!("[{code}] {message}");
                }
                Some(_) => continue,
                None => bail!("Connection closed before receiving list"),
            }
        }
    }
}
