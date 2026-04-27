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
