XCODE_PROJECT ?= OrbitDock/OrbitDock.xcodeproj
XCODE_SCHEME ?= OrbitDock
XCODE_DESTINATION ?= platform=macOS
XCODE_IOS_SCHEME ?= OrbitDock iOS
XCODE_IOS_DESTINATION ?= generic/platform=iOS
XCODEBUILD_BASE = xcodebuild -project $(XCODE_PROJECT) -scheme "$(XCODE_SCHEME)" -destination "$(XCODE_DESTINATION)"
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
XCODEBUILD_IOS = $(XCODEBUILD_ENV) $(XCODEBUILD_IOS_BASE) $(XCODEBUILD_ARGS)
RUST_WORKSPACE_DIR ?= orbitdock-server
SCCACHE_CACHE_SIZE ?= 20G
RUST_ENV_CLEAN = env -u RUSTC_WRAPPER -u CARGO_BUILD_RUSTC_WRAPPER SCCACHE_CACHE_SIZE=$(SCCACHE_CACHE_SIZE)
SHELL := /bin/bash

.DEFAULT_GOAL := build

.PHONY: help build build-ios build-all clean test test-all test-unit test-ui fmt lint swift-fmt swift-lint rust-build rust-check rust-test rust-fmt rust-lint rust-run rust-run-debug rust-release-darwin rust-release-linux release rust-sccache-start rust-sccache-stop rust-sccache-stats rust-sccache-zero rust-env rust-clean rust-clean-release rust-clean-release-darwin rust-clean-release-linux whisper-model xcode-cache-dirs

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
	@echo "make rust-build Build Rust server crate"
	@echo "make rust-check Run cargo check for Rust workspace"
	@echo "make rust-test  Run Rust workspace tests"
	@echo "make rust-fmt   Format Rust with cargo fmt"
	@echo "make rust-lint  Lint Rust workspace"
	@echo "make rust-run   Run orbitdock-server in dev mode"
	@echo "make rust-run-debug Run orbitdock-server with debug logs"
	@echo "make rust-release-darwin Build + package orbitdock-server-darwin-universal.zip"
	@echo "make rust-release-linux  Build + package orbitdock-server-linux-x86_64.zip"
	@echo "make release             Alias for rust-release-darwin"
	@echo "make rust-sccache-start  Start sccache server"
	@echo "make rust-sccache-stats  Show sccache stats"
	@echo "make rust-sccache-zero   Reset sccache stats"
	@echo "make rust-env            Show Rust/sccache env state"
	@echo "make rust-clean          Clean all Rust build artifacts"
	@echo "make rust-clean-release  Clean Rust release artifacts only"
	@echo "make whisper-model Download ggml-base.en.bin into app resources"

build:
	@$(MAKE) xcode-cache-dirs
	@mkdir -p $(XCODEBUILD_LOG_DIR)
	@$(XCODEBUILD) build 2>&1 | tee "$(XCODEBUILD_LOG_DIR)/xcodebuild-build.log" | xcbeautify --quiet

build-ios:
	@$(MAKE) xcode-cache-dirs
	@mkdir -p $(XCODEBUILD_LOG_DIR)
	@$(XCODEBUILD_IOS) build 2>&1 | tee "$(XCODEBUILD_LOG_DIR)/xcodebuild-build-ios.log" | xcbeautify --quiet

build-all: build build-ios

test: test-unit

test-unit:
	@$(MAKE) xcode-cache-dirs
	@$(XCODEBUILD) -only-testing:OrbitDockTests -skip-testing:OrbitDockUITests test 2>&1 | xcbeautify

test-ui:
	@$(MAKE) xcode-cache-dirs
	@$(XCODEBUILD) -only-testing:OrbitDockUITests test 2>&1 | xcbeautify

test-all:
	@$(MAKE) xcode-cache-dirs
	@$(XCODEBUILD) test 2>&1 | xcbeautify

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
	@echo "RUSTC_WRAPPER=$$RUSTC_WRAPPER"
	@echo "CARGO_BUILD_RUSTC_WRAPPER=$$CARGO_BUILD_RUSTC_WRAPPER"
	@echo "SCCACHE_CACHE_SIZE=$(SCCACHE_CACHE_SIZE)"
	@echo "Using sanitized Rust env: $(RUST_ENV_CLEAN)"

rust-sccache-start:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV_CLEAN) sccache --start-server >/dev/null 2>&1 || true

rust-sccache-stop:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV_CLEAN) sccache --stop-server >/dev/null 2>&1 || true

rust-sccache-zero:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV_CLEAN) sccache --zero-stats

rust-sccache-stats:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV_CLEAN) sccache --show-stats

rust-build:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV_CLEAN) cargo build -p orbitdock-server

rust-check:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV_CLEAN) cargo check --workspace

rust-test:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV_CLEAN) cargo test --workspace -- --test-threads=1

rust-fmt:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV_CLEAN) cargo fmt --all

rust-lint:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV_CLEAN) cargo clippy --workspace --all-targets

rust-run:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV_CLEAN) cargo run -p orbitdock-server

rust-run-debug:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV_CLEAN) ORBITDOCK_SERVER_LOG_FILTER=debug cargo run -p orbitdock-server

rust-release-darwin:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV_CLEAN) ./package-release-assets.sh darwin

rust-release-linux:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV_CLEAN) ./package-release-assets.sh linux

release: rust-release-darwin

rust-clean:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV_CLEAN) cargo clean

rust-clean-release-darwin:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV_CLEAN) cargo clean --profile release --target aarch64-apple-darwin
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV_CLEAN) cargo clean --profile release --target x86_64-apple-darwin

rust-clean-release-linux:
	cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV_CLEAN) cargo clean --profile release --target x86_64-unknown-linux-gnu

rust-clean-release: rust-clean-release-darwin rust-clean-release-linux

whisper-model:
	@./OrbitDock/Scripts/download-whisper-model.sh

xcode-cache-dirs:
	@mkdir -p $(XCODE_DERIVED_DATA_DIR) $(XCODE_PACKAGE_CACHE_DIR) $(XCODE_SOURCE_PACKAGES_DIR) $(XCODE_CLANG_MODULE_CACHE_DIR) $(XCODE_SWIFTPM_MODULECACHE_DIR)
