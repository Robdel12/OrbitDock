//! Secure auth token lifecycle and verification.
//!
//! Tokens are issued as `odtk_<id>_<secret>`.
//! Only salted hashes are stored in SQLite.

use anyhow::Context;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use ring::digest::{Context as DigestContext, SHA256};
use ring::rand::{SecureRandom, SystemRandom};
use rusqlite::{params, Connection};

use crate::{migration_runner, paths};

const TOKEN_PREFIX: &str = "odtk";
const TOKEN_ID_BYTES: usize = 9;
const TOKEN_SECRET_BYTES: usize = 32;
const TOKEN_SALT_BYTES: usize = 16;
const HASH_BYTES: usize = 32;
const MAX_TOKEN_DELIMITERS_TO_TRY: usize = 64;

#[derive(Debug, Clone)]
pub struct IssuedToken {
    pub id: String,
    pub token: String,
}

#[derive(Debug, Clone)]
pub struct TokenRecord {
    pub id: String,
    pub label: Option<String>,
    pub created_at: String,
    pub last_used_at: Option<String>,
    pub expires_at: Option<String>,
    pub revoked_at: Option<String>,
}

pub fn issue_token(label: Option<&str>) -> anyhow::Result<IssuedToken> {
    let conn = open_admin_connection()?;
    let rng = SystemRandom::new();
    let label = label
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(ToString::to_string);

    for _ in 0..8 {
        let id = random_string(&rng, TOKEN_ID_BYTES)?;
        let secret = random_string(&rng, TOKEN_SECRET_BYTES)?;
        let salt = random_bytes::<TOKEN_SALT_BYTES>(&rng)?;
        let hash = hash_secret(&salt, &secret);

        let inserted = conn
            .execute(
                "INSERT INTO auth_tokens (id, token_hash, token_salt, label)
                 VALUES (?1, ?2, ?3, ?4)",
                params![id, hash.to_vec(), salt.to_vec(), label.as_deref()],
            )
            .with_context(|| "insert auth token")?;

        if inserted == 1 {
            return Ok(IssuedToken {
                id: id.clone(),
                token: format!("{}_{}_{}", TOKEN_PREFIX, id, secret),
            });
        }
    }

    anyhow::bail!("failed to generate a unique auth token id")
}

pub fn active_token_count() -> anyhow::Result<i64> {
    let conn = open_runtime_connection()?;
    let count = conn.query_row(
        "SELECT COUNT(*) FROM auth_tokens
         WHERE revoked_at IS NULL
           AND (expires_at IS NULL OR expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
        [],
        |row| row.get::<_, i64>(0),
    )?;
    Ok(count)
}

pub fn list_tokens() -> anyhow::Result<Vec<TokenRecord>> {
    let conn = open_admin_connection()?;
    let mut stmt = conn.prepare(
        "SELECT id, label, created_at, last_used_at, expires_at, revoked_at
         FROM auth_tokens
         ORDER BY datetime(created_at) DESC",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok(TokenRecord {
            id: row.get(0)?,
            label: row.get(1)?,
            created_at: row.get(2)?,
            last_used_at: row.get(3)?,
            expires_at: row.get(4)?,
            revoked_at: row.get(5)?,
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn revoke_token(id: &str) -> anyhow::Result<bool> {
    let conn = open_admin_connection()?;
    let updated = conn.execute(
        "UPDATE auth_tokens
         SET revoked_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
         WHERE id = ?1 AND revoked_at IS NULL",
        params![id.trim()],
    )?;
    Ok(updated > 0)
}

pub fn verify_bearer_token(token: &str) -> anyhow::Result<bool> {
    let token_candidates = parse_token_candidates(token);
    if token_candidates.is_empty() {
        return Ok(false);
    }

    let conn = open_runtime_connection()?;
    let mut stmt = conn.prepare(
        "SELECT token_hash, token_salt
         FROM auth_tokens
         WHERE id = ?1
           AND revoked_at IS NULL
           AND (expires_at IS NULL OR expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
         LIMIT 1",
    )?;

    for (id, secret) in token_candidates {
        let row = stmt.query_row(params![id], |row| {
            let hash: Vec<u8> = row.get(0)?;
            let salt: Vec<u8> = row.get(1)?;
            Ok((hash, salt))
        });

        let (expected_hash, salt) = match row {
            Ok(v) => v,
            Err(rusqlite::Error::QueryReturnedNoRows) => continue,
            Err(e) => return Err(anyhow::Error::new(e).context("query auth token")),
        };

        if expected_hash.len() != HASH_BYTES || salt.len() != TOKEN_SALT_BYTES {
            continue;
        }

        let candidate_hash = hash_secret(&salt, secret);
        let is_match = constant_time_eq(&expected_hash, &candidate_hash);

        if is_match {
            let _ = conn.execute(
                "UPDATE auth_tokens
                 SET last_used_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                 WHERE id = ?1",
                params![id],
            );
            return Ok(true);
        }
    }

    Ok(false)
}

fn open_admin_connection() -> anyhow::Result<Connection> {
    paths::ensure_dirs().context("ensure data dirs for auth token db")?;
    let db_path = paths::db_path();
    let mut conn = Connection::open(&db_path)
        .with_context(|| format!("open auth token db at {}", db_path.display()))?;
    migration_runner::run_migrations(&mut conn).context("run auth token migrations")?;
    Ok(conn)
}

fn open_runtime_connection() -> anyhow::Result<Connection> {
    paths::ensure_dirs().context("ensure data dirs for auth token db")?;
    let db_path = paths::db_path();
    Connection::open(&db_path)
        .with_context(|| format!("open auth token db at {}", db_path.display()))
}

fn parse_token_candidates(token: &str) -> Vec<(&str, &str)> {
    let mut out = Vec::new();
    let payload = token.trim();
    let Some(payload) = payload.strip_prefix(TOKEN_PREFIX) else {
        return out;
    };
    let Some(payload) = payload.strip_prefix('_') else {
        return out;
    };

    for (idx, ch) in payload.char_indices() {
        if ch != '_' {
            continue;
        }
        if out.len() >= MAX_TOKEN_DELIMITERS_TO_TRY {
            break;
        }
        let id = &payload[..idx];
        let secret = &payload[idx + 1..];
        if id.is_empty() || secret.is_empty() {
            continue;
        }
        out.push((id, secret));
    }

    // Prefer the most likely split (latest delimiter) first.
    out.reverse();
    out
}

fn random_string(rng: &SystemRandom, byte_len: usize) -> anyhow::Result<String> {
    let mut bytes = vec![0u8; byte_len];
    rng.fill(&mut bytes)
        .map_err(|_| anyhow::anyhow!("failed to generate secure random bytes"))?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

fn random_bytes<const N: usize>(rng: &SystemRandom) -> anyhow::Result<[u8; N]> {
    let mut bytes = [0u8; N];
    rng.fill(&mut bytes)
        .map_err(|_| anyhow::anyhow!("failed to generate secure random bytes"))?;
    Ok(bytes)
}

fn hash_secret(salt: &[u8], secret: &str) -> [u8; HASH_BYTES] {
    let mut context = DigestContext::new(&SHA256);
    context.update(salt);
    context.update(secret.as_bytes());
    let digest = context.finish();
    let mut out = [0u8; HASH_BYTES];
    out.copy_from_slice(digest.as_ref());
    out
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    let max_len = left.len().max(right.len());
    let mut diff = left.len() ^ right.len();
    for idx in 0..max_len {
        let lhs = left.get(idx).copied().unwrap_or(0);
        let rhs = right.get(idx).copied().unwrap_or(0);
        diff |= (lhs ^ rhs) as usize;
    }
    diff == 0
}

#[cfg(test)]
mod tests {
    use super::parse_token_candidates;

    #[test]
    fn parse_token_candidates_rejects_invalid_prefix() {
        let candidates = parse_token_candidates("invalid_token");
        assert!(candidates.is_empty());
    }

    #[test]
    fn parse_token_candidates_supports_underscores_in_segments() {
        let token = "odtk_abc_def_ghi_jkl";
        let candidates = parse_token_candidates(token);
        assert!(candidates
            .iter()
            .any(|(id, secret)| *id == "abc_def" && *secret == "ghi_jkl"));
    }
}
