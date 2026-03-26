use orbitdock_protocol::WorkspaceProviderKind;
use serde::{Deserialize, Serialize};

use crate::cli::{ConfigAction, ConfigKey};
use crate::client::rest::RestClient;
use crate::error::{CliError, EXIT_CLIENT_ERROR, EXIT_SUCCESS};
use crate::output::Output;

#[derive(Debug, Deserialize, Serialize)]
struct WorkspaceProviderConfigResponse {
    workspace_provider: WorkspaceProviderKind,
}

#[derive(Debug, Serialize)]
struct SetWorkspaceProviderRequest {
    workspace_provider: WorkspaceProviderKind,
}

#[derive(Debug, Serialize)]
struct ConfigJsonResponse {
    ok: bool,
    key: &'static str,
    value: String,
}

pub async fn run(action: &ConfigAction, rest: &RestClient, output: &Output) -> i32 {
    match action {
        ConfigAction::Get { key } => get_config(*key, rest, output).await,
        ConfigAction::Set { key, value } => set_config(*key, value, rest, output).await,
    }
}

async fn get_config(key: ConfigKey, rest: &RestClient, output: &Output) -> i32 {
    match key {
        ConfigKey::WorkspaceProvider => match rest
            .get::<WorkspaceProviderConfigResponse>("/api/server/workspace-provider")
            .await
            .into_result()
        {
            Ok(response) => {
                print_value(
                    output,
                    "workspace-provider",
                    response.workspace_provider.as_str(),
                );
                EXIT_SUCCESS
            }
            Err((code, err)) => {
                output.print_error(&err);
                code
            }
        },
    }
}

async fn set_config(key: ConfigKey, value: &str, rest: &RestClient, output: &Output) -> i32 {
    match key {
        ConfigKey::WorkspaceProvider => {
            let provider = match value.parse::<WorkspaceProviderKind>() {
                Ok(provider) => provider,
                Err(message) => {
                    output.print_error(&CliError::new("invalid_config_value", message));
                    return EXIT_CLIENT_ERROR;
                }
            };

            match rest
                .put_json::<_, WorkspaceProviderConfigResponse>(
                    "/api/server/workspace-provider",
                    &SetWorkspaceProviderRequest {
                        workspace_provider: provider,
                    },
                )
                .await
                .into_result()
            {
                Ok(response) => {
                    print_value(
                        output,
                        "workspace-provider",
                        response.workspace_provider.as_str(),
                    );
                    EXIT_SUCCESS
                }
                Err((code, err)) => {
                    output.print_error(&err);
                    code
                }
            }
        }
    }
}

fn print_value(output: &Output, key: &'static str, value: &str) {
    if output.json {
        output.print_json_pretty(&ConfigJsonResponse {
            ok: true,
            key,
            value: value.to_string(),
        });
    } else {
        println!("{key}={value}");
    }
}
