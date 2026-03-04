//! `orbitdock pair` — generate a connection URL + QR code for clients.

use crate::auth_tokens;

pub fn run(tunnel_url: Option<&str>, show_qr: bool) -> anyhow::Result<()> {
    let env_token = std::env::var("ORBITDOCK_AUTH_TOKEN")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let active_db_tokens = auth_tokens::active_token_count().unwrap_or(0);

    // Determine server URL
    let base_url = if let Some(url) = tunnel_url {
        url.to_string()
    } else {
        // Try health check on localhost to detect running server
        let health_ok = std::process::Command::new("curl")
            .args([
                "-s",
                "--connect-timeout",
                "1",
                "--max-time",
                "2",
                "http://127.0.0.1:4000/health",
            ])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);

        if health_ok {
            "http://127.0.0.1:4000".to_string()
        } else {
            anyhow::bail!(
                "Cannot detect server URL. Either:\n\
                 - Start the server: orbitdock start\n\
                 - Provide a tunnel URL: orbitdock pair --tunnel-url https://..."
            );
        }
    };

    // Build the connection URL
    let use_tls = base_url.starts_with("https://");
    let host = base_url
        .trim_start_matches("https://")
        .trim_start_matches("http://")
        .trim_end_matches('/');

    let pair_url = if use_tls {
        format!("orbitdock://{}?tls=1", host)
    } else {
        format!("orbitdock://{}", host)
    };

    println!();
    println!("  OrbitDock Pairing");
    println!("  ─────────────────");
    println!();
    println!("  Server:  {}", base_url);
    if let Some(ref token) = env_token {
        println!("  Token:   {}...", &token[..8.min(token.len())]);
    } else if active_db_tokens > 0 {
        println!(
            "  Token:   required ({} active database token(s))",
            active_db_tokens
        );
    } else {
        println!("  Token:   (none — server accepts unauthenticated requests)");
    }
    println!("  TLS:     {}", if use_tls { "yes" } else { "no" });
    println!();
    println!("  Connection URL:");
    println!("  {}", pair_url);
    if env_token.is_some() || active_db_tokens > 0 {
        println!("  Note: token is intentionally not embedded in the URL.");
        println!("        Enter the auth token separately in client settings.");
    }

    if show_qr {
        println!();
        match render_qr(&pair_url) {
            Ok(qr_string) => {
                println!("{}", qr_string);
            }
            Err(e) => {
                println!("  (QR generation failed: {})", e);
            }
        }
    }

    println!();
    println!("  To connect from another machine (hooks only):");
    if env_token.is_some() || active_db_tokens > 0 {
        println!(
            "    orbitdock install-hooks --server-url {} --auth-token <token>",
            base_url
        );
        if active_db_tokens > 0 && env_token.is_none() {
            println!("    # Create a new token if you don't already have one:");
            println!("    orbitdock generate-token");
        }
    } else {
        println!("    orbitdock install-hooks --server-url {}", base_url);
    }
    println!();

    Ok(())
}

fn render_qr(data: &str) -> anyhow::Result<String> {
    use qrcode::QrCode;

    let code = QrCode::new(data.as_bytes())?;
    let string = code
        .render::<char>()
        .quiet_zone(true)
        .module_dimensions(2, 1)
        .build();

    Ok(string)
}
