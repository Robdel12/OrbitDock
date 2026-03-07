XCODE_PROJECT ?= OrbitDock/OrbitDock.xcodeproj
XCODE_SCHEME ?= OrbitDock
XCODE_DESTINATION ?= platform=macOS,arch=arm64
XCODE_UNIT_TEST_SCHEME ?= OrbitDock Unit Tests
XCODE_IOS_SCHEME ?= OrbitDock iOS
XCODE_IOS_DESTINATION ?= generic/platform=iOS
XCODE_MACOS_CODE_SIGN_FLAGS ?=
ifeq ($(CI),true)
XCODE_MACOS_CODE_SIGN_FLAGS = CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""
endif
XCODEBUILD_BASE = xcodebuild -project $(XCODE_PROJECT) -scheme "$(XCODE_SCHEME)" -destination "$(XCODE_DESTINATION)" $(XCODE_MACOS_CODE_SIGN_FLAGS)
XCODEBUILD_UNIT_TEST_BASE = xcodebuild -project $(XCODE_PROJECT) -scheme "$(XCODE_UNIT_TEST_SCHEME)" -destination "$(XCODE_DESTINATION)" $(XCODE_MACOS_CODE_SIGN_FLAGS)
XCODEBUILD_IOS_BASE = xcodebuild -project $(XCODE_PROJECT) -scheme "$(XCODE_IOS_SCHEME)" -destination "$(XCODE_IOS_DESTINATION)" CODE_SIGNING_ALLOWED=NO
XCODEBUILD_LOG_DIR ?= .logs
XCODE_DERIVED_DATA_DIR ?= .build/DerivedData
XCODE_CACHE_DIR ?= .cache/xcodebuild
XCODE_PACKAGE_CACHE_DIR ?= $(XCODE_CACHE_DIR)/package-cache
XCODE_SOURCE_PACKAGES_DIR ?= $(XCODE_CACHE_DIR)/source-packages
XCODE_CLANG_MODULE_CACHE_DIR ?= $(XCODE_CACHE_DIR)/clang-module-cache
XCODE_SWIFTPM_MODULECACHE_DIR ?= $(XCODE_CACHE_DIR)/swiftpm-module-cache
XCODEBUILD_ARGS = -derivedDataPath "$(abspath $(XCODE_DERIVED_DATA_DIR))" -packageCachePath "$(abspath $(XCODE_PACKAGE_CACHE_DIR))" -clonedSourcePackagesDirPath "$(abspath $(XCODE_SOURCE_PACKAGES_DIR))"
XCODEBUILD_ENV = CLANG_MODULE_CACHE_PATH="$(abspath $(XCODE_CLANG_MODULE_CACHE_DIR))" SWIFTPM_MODULECACHE_OVERRIDE="$(abspath $(XCODE_SWIFTPM_MODULECACHE_DIR))"
XCODEBUILD = $(XCODEBUILD_ENV) $(XCODEBUILD_BASE) $(XCODEBUILD_ARGS)
XCODEBUILD_UNIT_TEST = $(XCODEBUILD_ENV) $(XCODEBUILD_UNIT_TEST_BASE) $(XCODEBUILD_ARGS)
XCODEBUILD_IOS = $(XCODEBUILD_ENV) $(XCODEBUILD_IOS_BASE) $(XCODEBUILD_ARGS)
RUST_WORKSPACE_DIR ?= orbitdock-server
RUST_TARGET_DIR ?= $(abspath .cache/rust/target)
RUST_LEGACY_TARGET_DIR ?= $(abspath $(RUST_WORKSPACE_DIR)/target)
SCCACHE_DIR ?= $(abspath .cache/rust/sccache)
SCCACHE_CACHE_SIZE ?= 10G
RUST_SCCACHE ?= off
LINUX_AARCH64_PROFILE_PRESET ?= release-lowmem
LINUX_AARCH64_DOCKER_JOBS ?= 1
CLAUDE_SDK_DOCS_DIR ?= orbitdock-server/docs
CLAUDE_SDK_VERSION ?= 0.2.62
CLAUDE_SDK_PACKAGE ?= @anthropic-ai/claude-agent-sdk
CLAUDE_SDK_VERSION_FILE ?= $(CLAUDE_SDK_DOCS_DIR)/claude-agent-sdk-version.json
SCCACHE_BIN := $(shell command -v sccache 2>/dev/null)
RUST_PATH_PREFIX ?= $(HOME)/.cargo/bin:/opt/homebrew/bin:/usr/local/bin
RUST_PATH ?= $(RUST_PATH_PREFIX):$(PATH)
RUST_RUN_BIND ?= 127.0.0.1:4000
RUST_RUN_LAN_BIND ?= 0.0.0.0:4000
RUST_RUN_REMOTE_BIND ?= 0.0.0.0:4000
RUST_ENV_BASE = PATH="$(RUST_PATH)" SCCACHE_DIR="$(SCCACHE_DIR)" SCCACHE_CACHE_SIZE=$(SCCACHE_CACHE_SIZE) CARGO_TARGET_DIR="$(RUST_TARGET_DIR)" CARGO_INCREMENTAL=0
ifeq ($(RUST_SCCACHE),on)
RUST_ENV = env $(RUST_ENV_BASE) RUSTC_WRAPPER=sccache CARGO_BUILD_RUSTC_WRAPPER=sccache
else ifeq ($(RUST_SCCACHE),off)
RUST_ENV = env -u RUSTC_WRAPPER -u CARGO_BUILD_RUSTC_WRAPPER $(RUST_ENV_BASE)
else ifneq ($(strip $(SCCACHE_BIN)),)
RUST_ENV = env $(RUST_ENV_BASE) RUSTC_WRAPPER="$(SCCACHE_BIN)" CARGO_BUILD_RUSTC_WRAPPER="$(SCCACHE_BIN)"
else
RUST_ENV = env -u RUSTC_WRAPPER -u CARGO_BUILD_RUSTC_WRAPPER $(RUST_ENV_BASE)
endif
SHELL := /bin/bash

.DEFAULT_GOAL := build

.PHONY: help build build-ios build-all clean test test-all test-unit test-ui fmt lint swift-fmt swift-lint rust-ci rust-build rust-build-release rust-build-darwin rust-build-universal rust-check rust-test rust-fmt rust-fmt-check rust-lint rust-run rust-run-lan rust-run-remote rust-run-debug rust-generate-token rust-release-darwin rust-release-linux rust-release-linux-all rust-release-linux-x86_64 rust-release-linux-aarch64 rust-release-linux-smoke rust-release-linux-smoke-x86_64 rust-release-linux-smoke-aarch64 rust-release-linux-test rust-smoke-linux rust-smoke-linux-x86_64 rust-smoke-linux-aarch64 rust-release-linux-validate release rust-sccache-start rust-sccache-stop rust-sccache-stats rust-sccache-zero rust-env rust-lock-status rust-unlock rust-size rust-clean rust-clean-debug rust-clean-incremental rust-clean-sccache rust-clean-release rust-clean-release-darwin rust-clean-release-linux rust-clean-release-linux-x86_64 rust-clean-release-linux-aarch64 xcode-cache-dirs claude-sdk-version claude-sdk-update claude-sdk-audit-checklist

help:
	@echo "make build      Build the macOS app"
	@echo "make build-ios  Build the iOS app"
	@echo "make build-all  Build both macOS and iOS"
	@echo "make test       Run unit tests (no UI tests)"
	@echo "make test-unit  Run unit tests only (OrbitDockTests)"
	@echo "make test-ui    Run UI tests only (OrbitDockUITests)"
	@echo "make test-all   Run all tests"
	@echo "make clean      Clean build artifacts for the scheme"
	@echo "make fmt        Format Swift + Rust code"
	@echo "make lint       Lint Swift + Rust code"
	@echo "make swift-fmt  Format Swift with SwiftFormat"
	@echo "make swift-lint Lint Swift formatting with SwiftFormat --lint"
	@echo "make rust-build Build Rust orbitdock binary"
	@echo "make rust-build-release Build Rust orbitdock binary in release mode for the host platform"
	@echo "make rust-build-darwin Build fresh macOS arm64 orbitdock binary"
	@echo "make rust-build-universal Alias for rust-build-darwin (legacy target name)"
	@echo "make rust-check Run cargo check for Rust workspace"
	@echo "make rust-test  Run Rust workspace tests"
	@echo "make rust-ci    Run Rust fmt check + clippy + tests"
	@echo "make rust-fmt   Format Rust with cargo fmt"
	@echo "make rust-fmt-check Check Rust formatting with cargo fmt --check"
	@echo "make rust-lint  Lint Rust workspace"
	@echo "make rust-run   Run orbitdock locally (127.0.0.1:4000 by default)"
	@echo "make rust-run-lan Run on LAN without auth (trusted network/dev only)"
	@echo "make rust-run-remote Run orbitdock on 0.0.0.0 (requires DB token or ORBITDOCK_AUTH_TOKEN)"
	@echo "make rust-run-debug Run orbitdock with debug logs"
	@echo "make rust-generate-token Issue a secure auth token (stored hashed in DB)"
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
	@echo "make release             Alias for rust-release-darwin"
	@echo "make rust-size           Show Rust target/sccache disk usage"
	@echo "make rust-sccache-start  Start sccache server"
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
	@echo "make claude-sdk-version  Show installed Claude Agent SDK + Claude Code version"
	@echo "make claude-sdk-update CLAUDE_SDK_VERSION=0.2.62  Update docs SDK install and version metadata"
	@echo "make claude-sdk-audit-checklist  Print required source audit checklist"

build:
	@$(MAKE) xcode-cache-dirs
	@mkdir -p $(XCODEBUILD_LOG_DIR)
	@set -o pipefail; $(XCODEBUILD) build 2>&1 | tee "$(XCODEBUILD_LOG_DIR)/xcodebuild-build.log" | xcbeautify --quiet

build-ios:
	@$(MAKE) xcode-cache-dirs
	@mkdir -p $(XCODEBUILD_LOG_DIR)
	@set -o pipefail; $(XCODEBUILD_IOS) build 2>&1 | tee "$(XCODEBUILD_LOG_DIR)/xcodebuild-build-ios.log" | xcbeautify --quiet

build-all: build build-ios

test: test-unit

test-unit:
	@$(MAKE) xcode-cache-dirs
	@set -o pipefail; $(XCODEBUILD_UNIT_TEST) -parallel-testing-enabled NO test 2>&1 | xcbeautify

test-ui:
	@$(MAKE) xcode-cache-dirs
	@set -o pipefail; $(XCODEBUILD) -only-testing:OrbitDockUITests test 2>&1 | xcbeautify

test-all:
	@$(MAKE) xcode-cache-dirs
	@set -o pipefail; $(XCODEBUILD) test 2>&1 | xcbeautify

clean:
	@$(MAKE) xcode-cache-dirs
	$(XCODEBUILD) clean

fmt: swift-fmt rust-fmt

lint: swift-lint rust-lint

swift-fmt:
	swiftformat OrbitDock

swift-lint:
	swiftformat --lint OrbitDock

rust-env:
	@echo "RUST_SCCACHE=$(RUST_SCCACHE)"
	@echo "SCCACHE_BIN=$(if $(strip $(SCCACHE_BIN)),$(SCCACHE_BIN),<not found>)"
	@echo "RUST_TARGET_DIR=$(RUST_TARGET_DIR)"
	@echo "SCCACHE_DIR=$(SCCACHE_DIR)"
	@echo "CARGO_INCREMENTAL=0"
	@echo "RUSTC_WRAPPER=$$RUSTC_WRAPPER"
	@echo "CARGO_BUILD_RUSTC_WRAPPER=$$CARGO_BUILD_RUSTC_WRAPPER"
	@echo "SCCACHE_CACHE_SIZE=$(SCCACHE_CACHE_SIZE)"
	@if [[ -d "$(RUST_LEGACY_TARGET_DIR)" ]]; then \
		echo "LEGACY_TARGET_DIR=$(RUST_LEGACY_TARGET_DIR) (present)"; \
	else \
		echo "LEGACY_TARGET_DIR=<none>"; \
	fi
	@echo "Using Rust env: $(RUST_ENV)"

rust-lock-status:
	@set -euo pipefail; \
	if ! command -v lsof >/dev/null 2>&1; then \
		echo "lsof is required for rust-lock-status"; \
		exit 1; \
	fi; \
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
	fi; \
	echo "Cargo lock files:"; \
	printf '  %s\n' "$${lock_files[@]}"; \
	lock_pids=(); \
	while IFS= read -r lock_pid; do \
		lock_pids+=("$$lock_pid"); \
	done < <(lsof -t "$${lock_files[@]}" 2>/dev/null | sort -u); \
	if [[ $${#lock_pids[@]} -eq 0 ]]; then \
		echo ""; \
		echo "No active processes hold these lock files."; \
		exit 0; \
	fi; \
	echo ""; \
	echo "Active lock holders:"; \
	ps -o pid,ppid,etime,state,command -p "$$(IFS=,; echo "$${lock_pids[*]}")"

rust-unlock:
	@set -euo pipefail; \
	if ! command -v lsof >/dev/null 2>&1; then \
		echo "lsof is required for rust-unlock"; \
		exit 1; \
	fi; \
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
	fi; \
	lock_pids=(); \
	while IFS= read -r lock_pid; do \
		lock_pids+=("$$lock_pid"); \
	done < <(lsof -t "$${lock_files[@]}" 2>/dev/null | sort -u); \
	if [[ $${#lock_pids[@]} -eq 0 ]]; then \
		echo "No active lock holders found."; \
		exit 0; \
	fi; \
	echo "Stopping Cargo lock holders: $${lock_pids[*]}"; \
	for pid in "$${lock_pids[@]}"; do \
		kill "$$pid" 2>/dev/null || true; \
	done; \
	remaining_pids=(); \
	while IFS= read -r remaining_pid; do \
		remaining_pids+=("$$remaining_pid"); \
	done < <(lsof -t "$${lock_files[@]}" 2>/dev/null | sort -u); \
	if [[ $${#remaining_pids[@]} -gt 0 ]]; then \
		echo "Force-killing remaining lock holders: $${remaining_pids[*]}"; \
		for pid in "$${remaining_pids[@]}"; do \
			kill -9 "$$pid" 2>/dev/null || true; \
		done; \
	fi; \
	echo "Cargo lock holders cleared."

rust-size:
	@if [[ -d "$(RUST_TARGET_DIR)" ]]; then \
		echo "Rust target dir size:"; \
		du -sh "$(RUST_TARGET_DIR)"; \
		echo ""; \
		echo "Largest target subdirs:"; \
		du -sh "$(RUST_TARGET_DIR)"/* 2>/dev/null | sort -h | tail -n 30; \
	else \
		echo "Rust target dir not found: $(RUST_TARGET_DIR)"; \
	fi
	@if [[ -d "$(SCCACHE_DIR)" ]]; then \
		echo ""; \
		echo "sccache dir size:"; \
		du -sh "$(SCCACHE_DIR)"; \
	fi
	@if [[ -d "$(RUST_LEGACY_TARGET_DIR)" ]]; then \
		echo ""; \
		echo "legacy target dir size:"; \
		du -sh "$(RUST_LEGACY_TARGET_DIR)"; \
	fi

rust-sccache-start:
	@if command -v sccache >/dev/null 2>&1; then \
		cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) sccache --start-server >/dev/null 2>&1 || true; \
	else \
		echo "sccache not found (install with: brew install sccache)"; \
	fi

rust-sccache-stop:
	@if command -v sccache >/dev/null 2>&1; then \
		cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) sccache --stop-server >/dev/null 2>&1 || true; \
	else \
		echo "sccache not found (install with: brew install sccache)"; \
	fi

rust-sccache-zero:
	@if command -v sccache >/dev/null 2>&1; then \
		cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) sccache --zero-stats; \
	else \
		echo "sccache not found (install with: brew install sccache)"; \
	fi

rust-sccache-stats:
	@if command -v sccache >/dev/null 2>&1; then \
		cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) sccache --show-stats; \
	else \
		echo "sccache not found (install with: brew install sccache)"; \
	fi

rust-ci: rust-fmt-check rust-lint rust-test

rust-build:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) cargo build -p orbitdock

rust-build-release:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) cargo build -p orbitdock --release

rust-build-darwin:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) rustup target add aarch64-apple-darwin
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) cargo build -p orbitdock --release --target aarch64-apple-darwin
	@mkdir -p "$(RUST_TARGET_DIR)/darwin-arm64"
	cp "$(RUST_TARGET_DIR)/aarch64-apple-darwin/release/orbitdock" "$(RUST_TARGET_DIR)/darwin-arm64/orbitdock"
	@chmod +x "$(RUST_TARGET_DIR)/darwin-arm64/orbitdock"
	@./OrbitDock/Scripts/server-source-fingerprint.sh > "$(RUST_TARGET_DIR)/darwin-arm64/orbitdock.gitsha"

rust-build-universal: rust-build-darwin

rust-check:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) cargo check --workspace

rust-test:
	cd $(RUST_WORKSPACE_DIR) && RUST_MIN_STACK=8388608 $(RUST_ENV) cargo test --workspace -- --test-threads=1

rust-fmt:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) cargo fmt --all

rust-fmt-check:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) cargo fmt --all -- --check

rust-lint:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) cargo clippy --workspace --all-targets -- -D warnings

rust-run:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) cargo run -p orbitdock -- start --bind $(RUST_RUN_BIND)

rust-run-lan:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) cargo run -p orbitdock -- start --bind $(RUST_RUN_LAN_BIND) --allow-insecure-no-auth

rust-run-remote:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) cargo run -p orbitdock -- start --bind $(RUST_RUN_REMOTE_BIND)

rust-run-debug:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) ORBITDOCK_SERVER_LOG_FILTER=debug cargo run -p orbitdock -- start

rust-generate-token:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) cargo run -p orbitdock -- generate-token


rust-release-darwin:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) ./package-release-assets.sh darwin

rust-release-linux:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) ./package-release-assets.sh linux

rust-release-linux-all: rust-release-linux-x86_64 rust-release-linux-aarch64

rust-release-linux-x86_64:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) ./package-release-assets.sh linux-x86_64

rust-release-linux-aarch64:
	cd $(RUST_WORKSPACE_DIR) && ORBITDOCK_LINUX_PROFILE_PRESET=$(LINUX_AARCH64_PROFILE_PRESET) ORBITDOCK_LINUX_DOCKER_CARGO_BUILD_JOBS=$(LINUX_AARCH64_DOCKER_JOBS) $(RUST_ENV) ./package-release-assets.sh linux-aarch64

rust-release-linux-smoke: rust-release-linux-smoke-x86_64 rust-release-linux-smoke-aarch64

rust-release-linux-smoke-x86_64:
	cd $(RUST_WORKSPACE_DIR) && ORBITDOCK_LINUX_PROFILE_PRESET=smoke $(RUST_ENV) ./package-release-assets.sh linux-x86_64

rust-release-linux-smoke-aarch64:
	cd $(RUST_WORKSPACE_DIR) && ORBITDOCK_LINUX_PROFILE_PRESET=smoke $(RUST_ENV) ./package-release-assets.sh linux-aarch64

rust-smoke-linux: rust-smoke-linux-x86_64 rust-smoke-linux-aarch64

rust-smoke-linux-x86_64:
	@set -euo pipefail; \
	tmpdir=$$(mktemp -d); \
	unzip -q dist/orbitdock-linux-x86_64.zip -d "$$tmpdir"; \
	docker run --rm --platform linux/amd64 -v "$$tmpdir:/work" --entrypoint /work/orbitdock rust:1-bookworm --version; \
	rm -rf "$$tmpdir"

rust-smoke-linux-aarch64:
	@set -euo pipefail; \
	tmpdir=$$(mktemp -d); \
	unzip -q dist/orbitdock-linux-aarch64.zip -d "$$tmpdir"; \
	docker run --rm --platform linux/arm64 -v "$$tmpdir:/work" --entrypoint /work/orbitdock rust:1-bookworm --version; \
	rm -rf "$$tmpdir"

rust-release-linux-test: rust-smoke-linux

rust-release-linux-validate: rust-release-linux-smoke rust-release-linux-test

release: rust-release-darwin

rust-clean:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) cargo clean

rust-clean-debug:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) cargo clean --profile dev
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) cargo clean --profile test

rust-clean-incremental:
	@if [[ -d "$(RUST_TARGET_DIR)" ]]; then \
		find "$(RUST_TARGET_DIR)" -type d -name incremental -prune -exec rm -rf {} +; \
		echo "Removed incremental caches under $(RUST_TARGET_DIR)"; \
	else \
		echo "Rust target dir not found: $(RUST_TARGET_DIR)"; \
	fi

rust-clean-sccache:
	@rm -rf "$(SCCACHE_DIR)"
	@echo "Removed sccache dir: $(SCCACHE_DIR)"

rust-clean-release-darwin:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) cargo clean --profile release --target aarch64-apple-darwin
	@rm -rf "$(RUST_TARGET_DIR)/darwin-arm64" "$(RUST_TARGET_DIR)/universal"

rust-clean-release-linux: rust-clean-release-linux-x86_64

rust-clean-release-linux-x86_64:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) cargo clean --profile release --target x86_64-unknown-linux-gnu

rust-clean-release-linux-aarch64:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) cargo clean --profile release --target aarch64-unknown-linux-gnu

rust-clean-release: rust-clean-release-darwin rust-clean-release-linux-x86_64 rust-clean-release-linux-aarch64

xcode-cache-dirs:
	@mkdir -p $(XCODE_DERIVED_DATA_DIR) $(XCODE_PACKAGE_CACHE_DIR) $(XCODE_SOURCE_PACKAGES_DIR) $(XCODE_CLANG_MODULE_CACHE_DIR) $(XCODE_SWIFTPM_MODULECACHE_DIR)

claude-sdk-version:
	@node -e 'const fs=require("fs");const path="$(CLAUDE_SDK_DOCS_DIR)/node_modules/@anthropic-ai/claude-agent-sdk/package.json";if(!fs.existsSync(path)){console.error("Claude Agent SDK not installed: "+path);process.exit(1);}const pkg=JSON.parse(fs.readFileSync(path,"utf8"));console.log(`${pkg.name}@${pkg.version} (claudeCodeVersion=${pkg.claudeCodeVersion??"unknown"})`);'

claude-sdk-update:
	cd $(CLAUDE_SDK_DOCS_DIR) && npm install $(CLAUDE_SDK_PACKAGE)@$(CLAUDE_SDK_VERSION)
	@node -e 'const fs=require("fs");const pkgPath="$(CLAUDE_SDK_DOCS_DIR)/node_modules/@anthropic-ai/claude-agent-sdk/package.json";if(!fs.existsSync(pkgPath)){console.error("Missing installed SDK package: "+pkgPath);process.exit(1);}const pkg=JSON.parse(fs.readFileSync(pkgPath,"utf8"));const out={packageName:pkg.name,sdkVersion:pkg.version,claudeCodeVersion:pkg.claudeCodeVersion??null,sourcePath:"orbitdock-server/docs/node_modules/@anthropic-ai/claude-agent-sdk",officialOverview:"https://platform.claude.com/docs/en/agent-sdk/overview",auditDoc:`orbitdock-server/docs/claude-agent-sdk-${pkg.version}-source-audit.md`};fs.writeFileSync("$(CLAUDE_SDK_VERSION_FILE)",JSON.stringify(out,null,2)+"\\n");console.log(`Wrote $(CLAUDE_SDK_VERSION_FILE)`);'

claude-sdk-audit-checklist:
	@echo "Claude Agent SDK audit checklist:"
	@echo "1. Update local install: make claude-sdk-update CLAUDE_SDK_VERSION=<version>"
	@echo "2. Inspect source of truth files:"
	@echo "   - orbitdock-server/docs/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs"
	@echo "   - orbitdock-server/docs/node_modules/@anthropic-ai/claude-agent-sdk/sdk.d.ts"
	@echo "   - orbitdock-server/docs/node_modules/@anthropic-ai/claude-agent-sdk/sdk-tools.d.ts"
	@echo "   - orbitdock-server/docs/node_modules/@anthropic-ai/claude-agent-sdk/cli.js"
	@echo "3. Record findings in orbitdock-server/docs/claude-agent-sdk-<version>-source-audit.md"
	@echo "4. Update orbitdock-server/docs/claude-agent-sdk-version.json"
	@echo "5. If official docs differ, treat local source as truth"
