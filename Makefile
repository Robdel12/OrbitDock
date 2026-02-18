XCODE_PROJECT ?= OrbitDock/OrbitDock.xcodeproj
XCODE_SCHEME ?= OrbitDock
XCODE_DESTINATION ?= platform=macOS
XCODEBUILD_BASE = xcodebuild -project $(XCODE_PROJECT) -scheme $(XCODE_SCHEME) -destination "$(XCODE_DESTINATION)"
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
RUST_WORKSPACE_DIR ?= orbitdock-server
SHELL := /bin/bash

.DEFAULT_GOAL := build

.PHONY: help build clean test test-all test-unit test-ui fmt lint swift-fmt swift-lint rust-build rust-check rust-test rust-fmt rust-lint xcode-cache-dirs

help:
	@echo "make build      Build the macOS app (compact output, full log in .logs/xcodebuild-build.log)"
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
	@echo "make rust-lint  Run cargo clippy for Rust workspace"

build:
	@$(MAKE) xcode-cache-dirs
	@mkdir -p $(XCODEBUILD_LOG_DIR)
	@log_file="$(XCODEBUILD_LOG_DIR)/xcodebuild-build.log"; \
	echo "Running xcodebuild (compact output). Full log: $$log_file"; \
	$(XCODEBUILD) build 2>&1 | tee "$$log_file" | rg --line-buffered \
		-e '^xcodebuild: error:' \
		-e '^--- xcodebuild: WARNING:' \
		-e '^note: Run script build phase' \
		-e '^\*\* BUILD (SUCCEEDED|FAILED) \*\*' \
		-e '^[^:]+:[0-9]+:[0-9]+: (error|warning):' \
		-e '^[^:]+:[0-9]+: (error|warning):' \
		-e '^(error|warning):'; \
	status=$${PIPESTATUS[0]}; \
	error_count=$$(rg -c \
		-e '^xcodebuild: error:' \
		-e '^[^:]+:[0-9]+:[0-9]+: error:' \
		-e '^[^:]+:[0-9]+: error:' \
		-e '^error:' \
		"$$log_file" || echo 0); \
	warning_count=$$(rg -c \
		-e '^--- xcodebuild: WARNING:' \
		-e '^[^:]+:[0-9]+:[0-9]+: warning:' \
		-e '^[^:]+:[0-9]+: warning:' \
		-e '^warning:' \
		"$$log_file" || echo 0); \
	echo "Build summary: $$error_count errors, $$warning_count warnings"; \
	exit $$status

test: test-unit

test-unit:
	@$(MAKE) xcode-cache-dirs
	$(XCODEBUILD) -only-testing:OrbitDockTests -skip-testing:OrbitDockUITests test

test-ui:
	@$(MAKE) xcode-cache-dirs
	$(XCODEBUILD) -only-testing:OrbitDockUITests test

test-all:
	@$(MAKE) xcode-cache-dirs
	$(XCODEBUILD) test

clean:
	@$(MAKE) xcode-cache-dirs
	$(XCODEBUILD) clean

fmt: swift-fmt rust-fmt

lint: swift-lint rust-lint

swift-fmt:
	swiftformat OrbitDock

swift-lint:
	swiftformat --lint OrbitDock

rust-build:
	cd $(RUST_WORKSPACE_DIR) && cargo build -p orbitdock-server

rust-check:
	cd $(RUST_WORKSPACE_DIR) && cargo check --workspace

rust-test:
	cd $(RUST_WORKSPACE_DIR) && cargo test --workspace

rust-fmt:
	cd $(RUST_WORKSPACE_DIR) && cargo fmt --all

rust-lint:
	cd $(RUST_WORKSPACE_DIR) && cargo clippy --workspace --all-targets

xcode-cache-dirs:
	@mkdir -p $(XCODE_DERIVED_DATA_DIR) $(XCODE_PACKAGE_CACHE_DIR) $(XCODE_SOURCE_PACKAGES_DIR) $(XCODE_CLANG_MODULE_CACHE_DIR) $(XCODE_SWIFTPM_MODULECACHE_DIR)
