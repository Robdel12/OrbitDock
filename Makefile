XCODE_PROJECT ?= CommandCenter/CommandCenter.xcodeproj
XCODE_SCHEME ?= CommandCenter
XCODE_DESTINATION ?= platform=macOS
XCODEBUILD_BASE = xcodebuild -project $(XCODE_PROJECT) -scheme $(XCODE_SCHEME) -destination "$(XCODE_DESTINATION)"
RUST_WORKSPACE_DIR ?= orbitdock-server

.DEFAULT_GOAL := build

.PHONY: help build clean test test-all test-unit test-ui fmt lint swift-fmt swift-lint rust-build rust-check rust-test rust-fmt rust-lint

help:
	@echo "make build      Build the macOS app"
	@echo "make test       Run unit tests (no UI tests)"
	@echo "make test-unit  Run unit tests only (CommandCenterTests)"
	@echo "make test-ui    Run UI tests only (CommandCenterUITests)"
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
	$(XCODEBUILD_BASE) build

test: test-unit

test-unit:
	$(XCODEBUILD_BASE) -only-testing:CommandCenterTests -skip-testing:CommandCenterUITests test

test-ui:
	$(XCODEBUILD_BASE) -only-testing:CommandCenterUITests test

test-all:
	$(XCODEBUILD_BASE) test

clean:
	$(XCODEBUILD_BASE) clean

fmt: swift-fmt rust-fmt

lint: swift-lint rust-lint

swift-fmt:
	swiftformat CommandCenter

swift-lint:
	swiftformat --lint CommandCenter

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
