use reqwest::StatusCode;
use serde::de::DeserializeOwned;

use crate::client::config::ClientConfig;
use crate::error::{ApiError, CliError};

/// HTTP client for the OrbitDock REST API.
pub struct RestClient {
    client: reqwest::Client,
    base_url: String,
    token: Option<String>,
}

pub enum RestResult<T> {
    Ok(T),
    ApiError { status: u16, error: ApiError },
    ConnectionError(String),
}

impl RestClient {
    pub fn new(config: &ClientConfig) -> Self {
        let client = reqwest::Client::builder()
            .connect_timeout(std::time::Duration::from_secs(3))
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .expect("failed to build HTTP client");

        Self {
            client,
            base_url: config.server_url.trim_end_matches('/').to_string(),
            token: config.token.clone(),
        }
    }

    pub async fn get<T: DeserializeOwned>(&self, path: &str) -> RestResult<T> {
        self.request(reqwest::Method::GET, path, None::<&()>).await
    }

    pub async fn post_json<B: serde::Serialize, T: DeserializeOwned>(
        &self,
        path: &str,
        body: &B,
    ) -> RestResult<T> {
        self.request(reqwest::Method::POST, path, Some(body)).await
    }

    pub async fn put_json<B: serde::Serialize, T: DeserializeOwned>(
        &self,
        path: &str,
        body: &B,
    ) -> RestResult<T> {
        self.request(reqwest::Method::PUT, path, Some(body)).await
    }

    pub async fn patch_json<B: serde::Serialize, T: DeserializeOwned>(
        &self,
        path: &str,
        body: &B,
    ) -> RestResult<T> {
        self.request(reqwest::Method::PATCH, path, Some(body)).await
    }

    pub async fn delete<T: DeserializeOwned>(&self, path: &str) -> RestResult<T> {
        self.request(reqwest::Method::DELETE, path, None::<&()>)
            .await
    }

    async fn request<B: serde::Serialize, T: DeserializeOwned>(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<&B>,
    ) -> RestResult<T> {
        let url = format!("{}{}", self.base_url, path);
        let mut req = self.client.request(method, &url);
        if let Some(ref token) = self.token {
            req = req.bearer_auth(token);
        }
        if let Some(body) = body {
            req = req.json(body);
        }

        match req.send().await {
            Ok(resp) => {
                let status = resp.status();
                if status.is_success() || status == StatusCode::ACCEPTED {
                    match resp.json::<T>().await {
                        Ok(body) => RestResult::Ok(body),
                        Err(e) => {
                            RestResult::ConnectionError(format!("Failed to parse response: {e}"))
                        }
                    }
                } else {
                    let error = resp.json::<ApiError>().await.unwrap_or(ApiError {
                        code: "unknown".to_string(),
                        error: format!("HTTP {status}"),
                    });
                    RestResult::ApiError {
                        status: status.as_u16(),
                        error,
                    }
                }
            }
            Err(e) => {
                if e.is_connect() {
                    RestResult::ConnectionError(format!(
                        "Cannot connect to OrbitDock server at {}. Is it running?",
                        self.base_url
                    ))
                } else if e.is_timeout() {
                    RestResult::ConnectionError(format!("Request to {} timed out", self.base_url))
                } else {
                    RestResult::ConnectionError(format!("Request failed: {e}"))
                }
            }
        }
    }
}

impl<T> RestResult<T> {
    /// Convert to a tuple of (exit_code, value) for command handlers.
    pub fn into_result(self) -> Result<T, (i32, CliError)> {
        match self {
            RestResult::Ok(v) => Ok(v),
            RestResult::ApiError { status, error } => {
                let exit_code = if status >= 500 {
                    crate::error::EXIT_SERVER_ERROR
                } else {
                    crate::error::EXIT_CLIENT_ERROR
                };
                Err((exit_code, CliError::new(error.code, error.error)))
            }
            RestResult::ConnectionError(msg) => Err((
                crate::error::EXIT_CONNECTION_ERROR,
                CliError::connection(msg),
            )),
        }
    }
}
