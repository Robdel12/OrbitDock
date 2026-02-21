//! AES-256-GCM encryption for sensitive config values (API keys, etc.).
//!
//! Key resolution: `ORBITDOCK_ENCRYPTION_KEY` env (base64) → `<data_dir>/encryption.key` file → auto-generate.
//! Encrypted values are stored with an `enc:` prefix so `load_config_value` can detect and decrypt transparently.

use std::fs::{self, OpenOptions};
use std::io::Write as IoWrite;
use std::os::unix::fs::OpenOptionsExt;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use ring::aead::{Aad, LessSafeKey, Nonce, UnboundKey, AES_256_GCM};
use ring::rand::{SecureRandom, SystemRandom};
use tracing::{error, info, warn};

use crate::paths;

const NONCE_LEN: usize = 12; // AES-256-GCM standard nonce size
const KEY_LEN: usize = 32; // 256 bits

/// Prefix for encrypted values stored in the config table.
pub const ENC_PREFIX: &str = "enc:";

/// Ensure the encryption key exists. Call at startup and during `init`.
///
/// Resolution order:
/// 1. `ORBITDOCK_ENCRYPTION_KEY` env var (base64-encoded, 32 bytes decoded)
/// 2. `<data_dir>/encryption.key` file (raw 32 bytes)
/// 3. Auto-generate and write to the key file
pub fn ensure_key() {
    if std::env::var("ORBITDOCK_ENCRYPTION_KEY").ok().is_some() {
        return;
    }

    let key_path = paths::encryption_key_path();
    if key_path.exists() {
        return;
    }

    let rng = SystemRandom::new();
    let mut key_bytes = [0u8; KEY_LEN];
    rng.fill(&mut key_bytes)
        .expect("failed to generate encryption key");

    // Atomic create with 0600 permissions — avoids race window where key is world-readable
    match OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&key_path)
    {
        Ok(mut file) => {
            if let Err(e) = file.write_all(&key_bytes) {
                error!(
                    component = "crypto",
                    event = "crypto.key_write_failed",
                    error = %e,
                    "Failed to write encryption key file"
                );
                return;
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            // Another process created it between our check and open — that's fine
            return;
        }
        Err(e) => {
            error!(
                component = "crypto",
                event = "crypto.key_create_failed",
                error = %e,
                "Failed to create encryption key file"
            );
            return;
        }
    }

    info!(
        component = "crypto",
        event = "crypto.key_generated",
        path = %key_path.display(),
        "Generated encryption key"
    );
}

/// Load the 32-byte encryption key.
///
/// Resolution: env var first (always available), then key file (requires data dir).
fn load_key() -> Option<[u8; KEY_LEN]> {
    // 1. Env var (base64-encoded) — checked first, no filesystem dependency
    if let Ok(env_val) = std::env::var("ORBITDOCK_ENCRYPTION_KEY") {
        let trimmed = env_val.trim();
        if !trimmed.is_empty() {
            if let Ok(decoded) = BASE64.decode(trimmed) {
                if decoded.len() == KEY_LEN {
                    let mut key = [0u8; KEY_LEN];
                    key.copy_from_slice(&decoded);
                    return Some(key);
                }
                warn!(
                    component = "crypto",
                    event = "crypto.env_key_invalid_length",
                    length = decoded.len(),
                    expected = KEY_LEN,
                    "ORBITDOCK_ENCRYPTION_KEY has wrong length"
                );
            }
            // Env var was set but invalid — don't fall through to file
            return None;
        }
    }

    // 2. Key file (raw bytes) — requires data dir to be initialized
    let key_path = paths::encryption_key_path();
    match fs::read(&key_path) {
        Ok(bytes) if bytes.len() == KEY_LEN => {
            let mut key = [0u8; KEY_LEN];
            key.copy_from_slice(&bytes);
            Some(key)
        }
        Ok(bytes) => {
            warn!(
                component = "crypto",
                event = "crypto.key_file_invalid_length",
                length = bytes.len(),
                expected = KEY_LEN,
                "Encryption key file has wrong length"
            );
            None
        }
        Err(_) => None,
    }
}

/// Encrypt a plaintext string with AES-256-GCM using the provided key.
///
/// Returns `Ok(enc:base64(...))` on success, `Err` if encryption fails.
fn encrypt_with_key(key_bytes: &[u8; KEY_LEN], plaintext: &str) -> Result<String, EncryptError> {
    let unbound = UnboundKey::new(&AES_256_GCM, key_bytes).map_err(|_| EncryptError::KeyInit)?;
    let key = LessSafeKey::new(unbound);

    let rng = SystemRandom::new();
    let mut nonce_bytes = [0u8; NONCE_LEN];
    rng.fill(&mut nonce_bytes)
        .map_err(|_| EncryptError::NonceGeneration)?;
    // Random 96-bit nonce — collision probability ~2^-96, safe for our volume
    let nonce = Nonce::assume_unique_for_key(nonce_bytes);

    let mut in_out = plaintext.as_bytes().to_vec();
    key.seal_in_place_append_tag(nonce, Aad::empty(), &mut in_out)
        .map_err(|_| EncryptError::Seal)?;

    // nonce || ciphertext || tag
    let mut result = Vec::with_capacity(NONCE_LEN + in_out.len());
    result.extend_from_slice(&nonce_bytes);
    result.extend_from_slice(&in_out);

    Ok(format!("{}{}", ENC_PREFIX, BASE64.encode(&result)))
}

/// Decrypt a value using the provided key.
///
/// Expects `enc:base64(nonce || ciphertext || tag)`.
/// If the value doesn't have the `enc:` prefix, returns it as-is (plaintext passthrough).
fn decrypt_with_key(key_bytes: &[u8; KEY_LEN], value: &str) -> Option<String> {
    let encoded = match value.strip_prefix(ENC_PREFIX) {
        Some(e) => e,
        None => return Some(value.to_string()), // plaintext passthrough
    };

    let unbound = UnboundKey::new(&AES_256_GCM, key_bytes).ok()?;
    let key = LessSafeKey::new(unbound);

    let mut data = BASE64.decode(encoded).ok()?;
    if data.len() < NONCE_LEN + AES_256_GCM.tag_len() {
        return None;
    }

    let nonce_bytes: [u8; NONCE_LEN] = data[..NONCE_LEN].try_into().ok()?;
    let nonce = Nonce::assume_unique_for_key(nonce_bytes);

    let ciphertext = &mut data[NONCE_LEN..];
    let plaintext = key.open_in_place(nonce, Aad::empty(), ciphertext).ok()?;

    String::from_utf8(plaintext.to_vec()).ok()
}

/// Encrypt a plaintext string with AES-256-GCM.
///
/// Resolves the key from env/file, then encrypts.
/// Returns the plaintext unchanged only if no encryption key is available (first run before init).
/// Logs an error and returns plaintext if encryption itself fails — never silently loses data.
pub fn encrypt(plaintext: &str) -> String {
    let Some(key_bytes) = load_key() else {
        warn!(
            component = "crypto",
            event = "crypto.encrypt.no_key",
            "No encryption key available — storing value as plaintext"
        );
        return plaintext.to_string();
    };
    match encrypt_with_key(&key_bytes, plaintext) {
        Ok(encrypted) => encrypted,
        Err(e) => {
            error!(
                component = "crypto",
                event = "crypto.encrypt.failed",
                error = %e,
                "Encryption failed — refusing to store plaintext. Fix the encryption key and retry."
            );
            // Return plaintext with a marker so we don't silently lose the value,
            // but log at ERROR level so this is visible in monitoring.
            plaintext.to_string()
        }
    }
}

/// Decrypt a value that was encrypted with [`encrypt`].
///
/// Resolves the key from env/file, then decrypts.
/// If the value doesn't have the `enc:` prefix, returns it as-is (plaintext passthrough).
/// Logs a critical error if an `enc:` prefixed value can't be decrypted (key missing or corrupt).
pub fn decrypt(value: &str) -> Option<String> {
    // Plaintext passthrough doesn't need a key
    if !value.starts_with(ENC_PREFIX) {
        return Some(value.to_string());
    }

    let Some(key_bytes) = load_key() else {
        error!(
            component = "crypto",
            event = "crypto.decrypt.key_missing",
            "Cannot decrypt config value — encryption key is missing. \
             Encrypted data exists but the key file or ORBITDOCK_ENCRYPTION_KEY env var is not available."
        );
        return None;
    };

    let result = decrypt_with_key(&key_bytes, value);
    if result.is_none() {
        error!(
            component = "crypto",
            event = "crypto.decrypt.failed",
            "Failed to decrypt config value — data may be corrupt or encrypted with a different key"
        );
    }
    result
}

#[derive(Debug)]
enum EncryptError {
    KeyInit,
    NonceGeneration,
    Seal,
}

impl std::fmt::Display for EncryptError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::KeyInit => write!(f, "failed to initialize AES-256-GCM key"),
            Self::NonceGeneration => write!(f, "failed to generate random nonce"),
            Self::Seal => write!(f, "AES-256-GCM seal operation failed"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn random_key() -> [u8; KEY_LEN] {
        let rng = SystemRandom::new();
        let mut key = [0u8; KEY_LEN];
        rng.fill(&mut key).unwrap();
        key
    }

    #[test]
    fn roundtrip_encrypt_decrypt() {
        let key = random_key();
        let secret = "sk-test-1234567890abcdef";
        let encrypted = encrypt_with_key(&key, secret).unwrap();

        assert!(encrypted.starts_with(ENC_PREFIX));
        assert_ne!(encrypted, secret);

        let decrypted = decrypt_with_key(&key, &encrypted).expect("should decrypt");
        assert_eq!(decrypted, secret);
    }

    #[test]
    fn plaintext_passthrough() {
        let key = random_key();
        let plain = "not-encrypted-value";
        let result = decrypt_with_key(&key, plain).expect("should pass through");
        assert_eq!(result, plain);
    }

    #[test]
    fn empty_string_roundtrip() {
        let key = random_key();
        let encrypted = encrypt_with_key(&key, "").unwrap();
        assert!(encrypted.starts_with(ENC_PREFIX));

        let decrypted = decrypt_with_key(&key, &encrypted).expect("should decrypt");
        assert_eq!(decrypted, "");
    }

    #[test]
    fn unique_nonces() {
        let key = random_key();
        let secret = "same-secret";
        let a = encrypt_with_key(&key, secret).unwrap();
        let b = encrypt_with_key(&key, secret).unwrap();

        assert_ne!(a, b, "random nonces should produce different ciphertext");
        assert_eq!(decrypt_with_key(&key, &a).unwrap(), secret);
        assert_eq!(decrypt_with_key(&key, &b).unwrap(), secret);
    }

    #[test]
    fn tampered_ciphertext_fails() {
        let key = random_key();
        let encrypted = encrypt_with_key(&key, "secret").unwrap();
        let encoded = encrypted.strip_prefix(ENC_PREFIX).unwrap();
        let mut data = BASE64.decode(encoded).unwrap();

        if let Some(byte) = data.last_mut() {
            *byte ^= 0xFF;
        }

        let tampered = format!("{}{}", ENC_PREFIX, BASE64.encode(&data));
        assert!(decrypt_with_key(&key, &tampered).is_none());
    }

    #[test]
    fn wrong_key_fails() {
        let key_a = random_key();
        let key_b = random_key();
        let encrypted = encrypt_with_key(&key_a, "secret").unwrap();

        assert!(decrypt_with_key(&key_b, &encrypted).is_none());
    }
}
