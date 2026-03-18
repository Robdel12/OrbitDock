mod doctor;
mod ensure_path;
mod hook_forward;
mod init;
mod install_hooks;
mod install_service;
mod pair;
mod remote_setup;
mod setup;
mod status;
mod tunnel;

pub use doctor::print_diagnostics;
pub use ensure_path::ensure_shell_path;
pub use hook_forward::{
    forward_hook_event, read_transport_config as read_hook_transport_config,
    write_transport_config as write_hook_transport_config, HookForwardType, HookTransportConfig,
};
pub use init::initialize_data_dir;
pub use install_hooks::install_claude_hooks;
pub use install_service::{
    install_background_service, install_background_service_with_options, ServiceOptions,
};
pub use pair::print_pairing_details;
pub use remote_setup::guide_remote_setup;
pub use setup::{run_setup_wizard, Mode as SetupMode, SetupOptions};
pub use status::{
    issue_auth_token, print_auth_tokens, print_generated_auth_token, print_local_token,
    print_server_status, revoke_auth_token,
};
pub use tunnel::start_cloudflare_tunnel;
