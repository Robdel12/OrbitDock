use thiserror::Error;

/// Errors that can occur in connectors
#[derive(Debug, Error)]
pub enum ConnectorError {
    #[error("JSON serialization error: {0}")]
    JsonError(#[from] serde_json::Error),

    #[error("Channel closed")]
    ChannelClosed,

    #[error("Provider error: {0}")]
    ProviderError(String),
}
