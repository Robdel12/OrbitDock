SHELL := /bin/bash

.DEFAULT_GOAL := build

# ── Apple / Xcode configuration ───────────────────────────────────────────────

XCODE_PROJECT ?= OrbitDockNative/OrbitDock.xcodeproj
XCODE_SCHEME ?= OrbitDock
XCODE_DESTINATION ?= platform=macOS,arch=arm64
XCODE_UNIT_TEST_SCHEME ?= OrbitDock Unit Tests
XCODE_IOS_SCHEME ?= OrbitDock iOS
XCODE_IOS_DESTINATION ?= generic/platform=iOS
XCODE_IOS_TEST_DESTINATION ?= platform=iOS Simulator,name=iPhone 16,OS=18.5
XCODE_IOS_DEVICE_NAME ?=
XCODE_IOS_DEVICE_ID ?=
XCODE_IOS_DEVICE_BUNDLE_ID ?= com.stubborn-mule-software.OrbitDock-iOS
XCODE_IOS_DEVICE_BUILD_FLAGS ?= -allowProvisioningUpdates
XCODEBUILD_LOG_DIR ?= .logs
XCODE_DERIVED_DATA_DIR ?= .build/DerivedData
XCODE_CACHE_DIR ?= .cache/xcodebuild
XCODE_PACKAGE_CACHE_DIR ?= $(XCODE_CACHE_DIR)/package-cache
XCODE_SOURCE_PACKAGES_DIR ?= $(XCODE_CACHE_DIR)/source-packages
XCODE_CLANG_MODULE_CACHE_DIR ?= $(XCODE_CACHE_DIR)/clang-module-cache
XCODE_SWIFTPM_MODULECACHE_DIR ?= $(XCODE_CACHE_DIR)/swiftpm-module-cache
XCODE_MACOS_CODE_SIGN_FLAGS ?=

ifeq ($(CI),true)
XCODE_MACOS_CODE_SIGN_FLAGS = CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""
endif

# ── Rust build configuration ─────────────────────────────────────────────────

RUST_WORKSPACE_DIR ?= orbitdock-server
RUST_TARGET_DIR ?= $(abspath .cache/rust/target)
RUST_LEGACY_TARGET_DIR ?= $(abspath $(RUST_WORKSPACE_DIR)/target)
RUST_BIN_PACKAGE ?= orbitdock
ORBITDOCK_INSTALL_ROOT ?= $(HOME)/.orbitdock
ORBITDOCK_INSTALLED_BIN ?= $(ORBITDOCK_INSTALL_ROOT)/bin/orbitdock
RUST_PATH_PREFIX ?= $(HOME)/.cargo/bin:/opt/homebrew/bin:/usr/local/bin
RUST_PATH ?= $(RUST_PATH_PREFIX):$(PATH)
RUST_HOST_TARGET ?= $(shell PATH="$(RUST_PATH_PREFIX):$$PATH" rustc -vV 2>/dev/null | sed -n 's/^host: //p')
RUST_RUN_BIND ?= 127.0.0.1:4000
RUST_RUN_LAN_BIND ?= 0.0.0.0:4000

SCCACHE_DIR ?= $(abspath .cache/rust/sccache)
SCCACHE_CACHE_SIZE ?= 5G
RUST_SCCACHE ?= auto
SCCACHE_BIN := $(shell command -v sccache 2>/dev/null)
RUSTC_BIN := $(shell PATH="$(RUST_PATH_PREFIX):$$PATH" rustup which rustc 2>/dev/null)
SCCACHE_READY := $(shell if [ -n "$(SCCACHE_BIN)" ] && [ -n "$(RUSTC_BIN)" ] && "$(SCCACHE_BIN)" "$(RUSTC_BIN)" -vV >/dev/null 2>&1; then echo 1; fi)

LINUX_AARCH64_PROFILE_PRESET ?= release-lowmem
LINUX_AARCH64_DOCKER_JOBS ?= 1

# ── Tooling / SDK configuration ──────────────────────────────────────────────

CLAUDE_SDK_DOCS_DIR ?= orbitdock-server/docs
CLAUDE_SDK_VERSION ?= 0.2.62
CLAUDE_SDK_PACKAGE ?= @anthropic-ai/claude-agent-sdk
CLAUDE_SDK_VERSION_FILE ?= $(CLAUDE_SDK_DOCS_DIR)/claude-agent-sdk-version.json
WEB_APP_DIR ?= orbitdock-web

XCODEBUILD_ARGS = -derivedDataPath "$(abspath $(XCODE_DERIVED_DATA_DIR))" -packageCachePath "$(abspath $(XCODE_PACKAGE_CACHE_DIR))" -clonedSourcePackagesDirPath "$(abspath $(XCODE_SOURCE_PACKAGES_DIR))"
XCODEBUILD_ENV = CLANG_MODULE_CACHE_PATH="$(abspath $(XCODE_CLANG_MODULE_CACHE_DIR))" SWIFTPM_MODULECACHE_OVERRIDE="$(abspath $(XCODE_SWIFTPM_MODULECACHE_DIR))"

define xcodebuild_cmd
$(XCODEBUILD_ENV) xcodebuild -project $(XCODE_PROJECT) -scheme "$(1)" -destination "$(2)" $(3) $(XCODEBUILD_ARGS)
endef

XCODEBUILD_MACOS = $(call xcodebuild_cmd,$(XCODE_SCHEME),$(XCODE_DESTINATION),$(XCODE_MACOS_CODE_SIGN_FLAGS))
XCODEBUILD_UNIT_TEST = $(call xcodebuild_cmd,$(XCODE_UNIT_TEST_SCHEME),$(XCODE_DESTINATION),$(XCODE_MACOS_CODE_SIGN_FLAGS))
XCODEBUILD_IOS = $(call xcodebuild_cmd,$(XCODE_IOS_SCHEME),$(XCODE_IOS_DESTINATION),CODE_SIGNING_ALLOWED=NO)
XCODEBUILD_IOS_UNIT_TEST = $(call xcodebuild_cmd,$(XCODE_IOS_SCHEME),$(XCODE_IOS_TEST_DESTINATION),CODE_SIGNING_ALLOWED=NO)

RUST_ENV_BASE = PATH="$(RUST_PATH)" SCCACHE_DIR="$(SCCACHE_DIR)" SCCACHE_CACHE_SIZE=$(SCCACHE_CACHE_SIZE) CARGO_TARGET_DIR="$(RUST_TARGET_DIR)" CARGO_INCREMENTAL=0

ifeq ($(RUST_SCCACHE),on)
RUST_ENV = env $(RUST_ENV_BASE) RUSTC_WRAPPER=sccache CARGO_BUILD_RUSTC_WRAPPER=sccache
else ifeq ($(RUST_SCCACHE),off)
RUST_ENV = env -u RUSTC_WRAPPER -u CARGO_BUILD_RUSTC_WRAPPER $(RUST_ENV_BASE)
else ifeq ($(strip $(SCCACHE_READY)),1)
RUST_ENV = env $(RUST_ENV_BASE) RUSTC_WRAPPER="$(SCCACHE_BIN)" CARGO_BUILD_RUSTC_WRAPPER="$(SCCACHE_BIN)"
else
RUST_ENV = env -u RUSTC_WRAPPER -u CARGO_BUILD_RUSTC_WRAPPER $(RUST_ENV_BASE)
endif

RUST_WORKSPACE_PREFIX = cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV)
RUST_CARGO = $(RUST_WORKSPACE_PREFIX) cargo

define run_xcode_logged
@$(MAKE) xcode-cache-dirs
@mkdir -p $(XCODEBUILD_LOG_DIR)
@set -o pipefail; $(1) 2>&1 | tee "$(XCODEBUILD_LOG_DIR)/$(2)" | xcbeautify --quiet
endef

define run_xcode_pretty
@$(MAKE) xcode-cache-dirs
@set -o pipefail; $(1) 2>&1 | xcbeautify
endef

define require_lsof
if ! command -v lsof >/dev/null 2>&1; then \
	echo "lsof is required for $(1)"; \
	exit 1; \
fi
endef

define gather_cargo_lock_files
lock_dirs=(); \
for dir in "$(RUST_TARGET_DIR)" "$(RUST_LEGACY_TARGET_DIR)"; do \
	if [[ -d "$$dir" ]]; then \
		lock_dirs+=("$$dir"); \
	fi; \
done; \
if [[ $${#lock_dirs[@]} -eq 0 ]]; then \
	echo "No Rust target directories found."; \
	exit 0; \
fi; \
lock_files=(); \
while IFS= read -r lock_file; do \
	lock_files+=("$$lock_file"); \
done < <(find "$${lock_dirs[@]}" -name .cargo-lock -type f 2>/dev/null | sort); \
if [[ $${#lock_files[@]} -eq 0 ]]; then \
	echo "No Cargo lock files found in target directories."; \
	exit 0; \
fi
endef

define gather_cargo_lock_pids
lock_pids=(); \
while IFS= read -r lock_pid; do \
	lock_pids+=("$$lock_pid"); \
done < <(lsof -t "$${lock_files[@]}" 2>/dev/null | sort -u)
endef

define with_sccache
@if command -v sccache >/dev/null 2>&1; then \
	$(RUST_WORKSPACE_PREFIX) sccache $(1); \
else \
	echo "sccache not found (install with: brew install sccache)"; \
fi
endef

define package_release
cd $(RUST_WORKSPACE_DIR) && $(2) $(RUST_ENV) ./package-release-assets.sh $(1)
endef

define smoke_linux_zip
@set -euo pipefail; \
tmpdir=$$(mktemp -d); \
unzip -q dist/orbitdock-linux-$(1).zip -d "$$tmpdir"; \
docker run --rm --platform $(2) -v "$$tmpdir:/work" --entrypoint /work/orbitdock rust:1-bookworm --version; \
rm -rf "$$tmpdir"
endef

define run_rust_start
	@args=(); \
	if [[ -t 1 && -t 2 && "$${ORBITDOCK_DEV_CONSOLE:-1}" != "0" ]]; then \
		args+=(--dev-console); \
	fi; \
	$(1) run -p $(RUST_BIN_PACKAGE) -- start $(2) "$${args[@]}"
endef

include make/swift.mk
include make/rust.mk
include make/claude-sdk.mk
include make/web.mk

.PHONY: help

help:
	@echo "Swift + App:"
	@echo "make build      Build the macOS app"
	@echo "make build-ios  Build the iOS app"
	@echo "make build-all  Build both macOS and iOS"
	@echo "make run-ios-device DEVICE='<device name>' | DEVICE_ID=<id>  Build, install, and launch on a physical iOS device"
	@echo "make test-unit  Run unit tests only (OrbitDockTests)"
	@echo "make test-unit-ios Run iOS unit tests only (OrbitDock iOSTests)"
	@echo "make test-ui    Run UI tests only (OrbitDockUITests)"
	@echo "make test-all   Run all tests"
	@echo "make clean      Clean build artifacts for the scheme"
	@echo "make fmt        Format Swift + Rust code"
	@echo "make lint       Lint Swift + Rust code"
	@echo "make swift-fmt  Format Swift with SwiftFormat"
	@echo "make swift-lint Lint Swift formatting with SwiftFormat --lint"
	@echo ""
	@echo "Rust:"
	@echo "make rust-build Build Rust orbitdock binary"
	@echo "make rust-build-release Build Rust orbitdock binary in release mode for the host platform"
	@echo "make rust-build-darwin Build fresh macOS arm64 orbitdock binary"
	@echo "make rust-install-local Build debug orbitdock and atomically install to ~/.orbitdock/bin"
	@echo "make rust-install-local-release Build release orbitdock and atomically install to ~/.orbitdock/bin"
	@echo "make rust-promote-local Build, install, and run orbitdock doctor against the installed binary"
	@echo "make rust-check Run fast cargo check for the shipped Rust package graph"
	@echo "make rust-check-workspace Run cargo check for the full Rust workspace"
	@echo "make rust-test  Run Rust workspace tests"
	@echo "make rust-ci    Run Rust fmt check + clippy + tests"
	@echo "make rust-fmt   Format Rust with cargo fmt"
	@echo "make rust-fmt-check Check Rust formatting with cargo fmt --check"
	@echo "make rust-lint  Lint Rust workspace"
	@echo "make rust-run   Run orbitdock locally (127.0.0.1:4000 by default)"
	@echo "make rust-run-lan Run on LAN without auth (trusted network/dev only)"
	@echo "make rust-run-debug Run orbitdock with debug logs"
	@echo "make rust-generate-token Issue a secure auth token (stored hashed in DB)"
	@echo "make cli ARGS='...'    Run the debug orbitdock binary with arbitrary args"
	@echo ""
	@echo "Release + Cache:"
	@echo "make rust-release-darwin Build + package orbitdock-darwin-arm64.zip"
	@echo "make rust-release-linux  Build + package host Linux arch zip (x86_64/aarch64); auto-uses Docker when needed"
	@echo "make rust-release-linux-all Build + package both Linux release zips"
	@echo "make rust-release-linux-x86_64 Build + package orbitdock-linux-x86_64.zip (auto Docker on macOS)"
	@echo "make rust-release-linux-aarch64 Build + package orbitdock-linux-aarch64.zip (auto Docker on macOS)"
	@echo "  aarch64 defaults: LINUX_AARCH64_PROFILE_PRESET=release-lowmem, LINUX_AARCH64_DOCKER_JOBS=1"
	@echo "  Override for full profile: make rust-release-linux-aarch64 LINUX_AARCH64_PROFILE_PRESET=release"
	@echo "make rust-release-linux-smoke-x86_64 Build fast local-validation Linux x86_64 zip"
	@echo "make rust-release-linux-smoke-aarch64 Build fast local-validation Linux aarch64 zip"
	@echo "make rust-release-linux-smoke Build both fast local-validation Linux zips"
	@echo "make rust-release-linux-test Run both Linux zips in matching Docker containers (--version)"
	@echo "make rust-release-linux-validate Build smoke zips + run smoke tests"
	@echo "make rust-size           Show Rust target/sccache disk usage"
	@echo "make rust-sccache-stats  Show sccache stats"
	@echo "make rust-sccache-zero   Reset sccache stats"
	@echo "make rust-env            Show Rust/sccache env state"
	@echo "make rust-lock-status    Show active Cargo artifact lock holders"
	@echo "make rust-unlock         Stop active Cargo lock holders for this repo"
	@echo "make rust-clean-debug    Clean only dev/test Rust artifacts"
	@echo "make rust-clean-incremental Remove incremental caches only"
	@echo "make rust-clean-sccache  Remove local sccache files"
	@echo "make rust-clean          Clean all Rust build artifacts"
	@echo "make rust-clean-release  Clean Rust release artifacts only"
	@echo ""
	@echo "Other:"
	@echo "make claude-sdk-version  Show installed Claude Agent SDK + Claude Code version"
	@echo "make claude-sdk-update CLAUDE_SDK_VERSION=0.2.62  Update local docs SDK install and metadata"
	@echo "make claude-sdk-audit-checklist  Print required source audit checklist"
	@echo "make release CHANNEL=stable BUMP=patch [VERSION_MODE=auto|explicit VERSION=...]  Trigger the server release workflow via gh"

.PHONY: release
release:
	@set -euo pipefail; \
	channel="$${CHANNEL:-stable}"; \
	version_mode="$${VERSION_MODE:-auto}"; \
	bump="$${BUMP:-patch}"; \
	version="$${VERSION:-}"; \
	build_server="$${BUILD_SERVER_ASSETS:-true}"; \
	publish_release="$${PUBLISH_RELEASE:-true}"; \
	args=(--field channel="$$channel" \
	      --field version_mode="$$version_mode" \
	      --field bump="$$bump" \
	      --field build_server_assets="$$build_server" \
	      --field publish_release="$$publish_release"); \
	if [[ -n "$$version" ]]; then \
	  args+=(--field version="$$version"); \
	fi; \
	echo "Triggering Release workflow: channel=$$channel version_mode=$$version_mode bump=$$bump"; \
	gh workflow run release.yml "$${args[@]}"
