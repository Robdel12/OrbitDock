use serde::Deserialize;

use crate::client::rest::RestClient;
use crate::error::EXIT_SUCCESS;
use crate::output::Output;

#[derive(Debug, Deserialize, serde::Serialize)]
struct HealthResponse {
    status: String,
    #[serde(default)]
    version: Option<String>,
}

pub async fn run(rest: &RestClient, output: &Output) -> i32 {
    match rest.get::<HealthResponse>("/health").await.into_result() {
        Ok(health) => {
            if output.json {
                output.print_json(&health);
            } else {
                let version = health.version.as_deref().unwrap_or("unknown");
                let style = console::Style::new().green().bold();
                println!(
                    "{} Server is running (version: {})",
                    style.apply_to("●"),
                    version
                );
            }
            EXIT_SUCCESS
        }
        Err((code, err)) => {
            output.print_error(&err);
            code
        }
    }
}
