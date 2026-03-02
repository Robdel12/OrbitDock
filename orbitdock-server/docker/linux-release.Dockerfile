# syntax=docker/dockerfile:1.7

ARG RUST_VERSION=1-bookworm
FROM rust:${RUST_VERSION} AS builder

ARG RUST_TARGET
ARG CARGO_PROFILE_RELEASE_LTO
ARG CARGO_PROFILE_RELEASE_CODEGEN_UNITS
ARG CARGO_BUILD_JOBS
WORKDIR /workspace

RUN apt-get update \
  && apt-get install -y --no-install-recommends pkg-config libcap-dev \
  && rm -rf /var/lib/apt/lists/*

COPY orbitdock-server ./orbitdock-server
COPY migrations ./migrations
WORKDIR /workspace/orbitdock-server

RUN rustup target add "${RUST_TARGET}"
RUN --mount=type=cache,id=orbitdock-cargo-registry,target=/usr/local/cargo/registry \
  --mount=type=cache,id=orbitdock-cargo-git,target=/usr/local/cargo/git \
  --mount=type=cache,id=orbitdock-rust-target,target=/workspace/.cache/rust/target \
  set -eu; \
  if [ -n "${CARGO_PROFILE_RELEASE_LTO:-}" ]; then \
    export CARGO_PROFILE_RELEASE_LTO="${CARGO_PROFILE_RELEASE_LTO}"; \
  fi; \
  if [ -n "${CARGO_PROFILE_RELEASE_CODEGEN_UNITS:-}" ]; then \
    export CARGO_PROFILE_RELEASE_CODEGEN_UNITS="${CARGO_PROFILE_RELEASE_CODEGEN_UNITS}"; \
  fi; \
  if [ -n "${CARGO_BUILD_JOBS:-}" ]; then \
    export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS}"; \
  fi; \
  cargo build -p orbitdock-server --release --target "${RUST_TARGET}"; \
  mkdir -p /workspace/export; \
  cp "/workspace/.cache/rust/target/${RUST_TARGET}/release/orbitdock-server" /workspace/export/orbitdock-server

FROM scratch AS export
ARG RUST_TARGET
COPY --from=builder /workspace/export/orbitdock-server /orbitdock-server
