#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd -P)"
MODELS_DIR="${REPO_ROOT}/OrbitDock/OrbitDock/WhisperModels"
MODEL_FILE="${MODELS_DIR}/ggml-base.en.bin"
MODEL_URL="${WHISPER_MODEL_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin}"

mkdir -p "${MODELS_DIR}"

if [[ -f "${MODEL_FILE}" ]]; then
  echo "Whisper model already present at ${MODEL_FILE}"
  exit 0
fi

TMP_FILE="${MODEL_FILE}.tmp"
trap 'rm -f "${TMP_FILE}"' EXIT

echo "Downloading Whisper model from ${MODEL_URL}"
curl -L --fail --progress-bar "${MODEL_URL}" -o "${TMP_FILE}"

FILE_SIZE_BYTES="$(wc -c < "${TMP_FILE}" | tr -d ' ')"
MIN_EXPECTED_BYTES=$((50 * 1024 * 1024))
if [[ "${FILE_SIZE_BYTES}" -lt "${MIN_EXPECTED_BYTES}" ]]; then
  echo "Downloaded file is unexpectedly small (${FILE_SIZE_BYTES} bytes). Aborting."
  exit 1
fi

mv "${TMP_FILE}" "${MODEL_FILE}"
trap - EXIT

echo "Saved model to ${MODEL_FILE}"
