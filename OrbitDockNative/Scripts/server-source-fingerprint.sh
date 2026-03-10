#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REF="${1:-HEAD}"

if ! git -C "$REPO_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "error: could not resolve git repository root for server source fingerprint" >&2
  exit 1
fi

server_tree="$(git -C "$REPO_ROOT" rev-parse "${REF}:orbitdock-server")"
migrations_tree="$(git -C "$REPO_ROOT" rev-parse "${REF}:migrations")"

dirty_state=""
if [[ "$REF" == "HEAD" ]]; then
  dirty_state="$(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all -- orbitdock-server migrations)"
fi

fingerprint_input="$(printf '%s\n%s\n--\n%s' "$server_tree" "$migrations_tree" "$dirty_state")"

if command -v sha256sum >/dev/null 2>&1; then
  printf '%s' "$fingerprint_input" | sha256sum | awk '{print $1}'
else
  printf '%s' "$fingerprint_input" | shasum -a 256 | awk '{print $1}'
fi
