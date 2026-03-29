.PHONY: \
	rust-env rust-lock-status rust-unlock rust-size \
	rust-sccache-stats rust-sccache-zero \
	rust-ci rust-build rust-build-release rust-build-darwin \
	rust-install-local rust-install-local-release rust-promote-local \
	rust-check rust-check-workspace rust-test rust-fmt rust-fmt-check rust-lint \
	rust-run rust-run-lan rust-run-debug rust-generate-token cli \
	rust-release-darwin rust-release-linux rust-release-linux-all rust-release-linux-x86_64 rust-release-linux-aarch64 \
	rust-release-linux-smoke rust-release-linux-smoke-x86_64 rust-release-linux-smoke-aarch64 \
	rust-release-linux-test rust-release-linux-validate \
	rust-clean rust-clean-debug rust-clean-incremental rust-clean-sccache \
	rust-clean-release rust-clean-release-darwin rust-clean-release-linux-x86_64 rust-clean-release-linux-aarch64

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
	$(call require_lsof,rust-lock-status); \
	$(call gather_cargo_lock_files); \
	echo "Cargo lock files:"; \
	printf '  %s\n' "$${lock_files[@]}"; \
	$(call gather_cargo_lock_pids); \
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
	$(call require_lsof,rust-unlock); \
	$(call gather_cargo_lock_files); \
	$(call gather_cargo_lock_pids); \
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
		du -sh "$(RUST_TARGET_DIR)" 2>/dev/null || true; \
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

rust-sccache-zero:
	$(call with_sccache,--zero-stats)

rust-sccache-stats:
	$(call with_sccache,--show-stats)

rust-ci: rust-fmt-check rust-lint rust-test

rust-build:
	$(RUST_CARGO) build -p $(RUST_BIN_PACKAGE)

rust-build-release: web-build
	$(RUST_CARGO) build -p $(RUST_BIN_PACKAGE) --release

rust-build-darwin: web-build
	@if [[ "$(RUST_HOST_TARGET)" == "aarch64-apple-darwin" ]]; then \
		$(RUST_CARGO) build -p $(RUST_BIN_PACKAGE) --release; \
	else \
		$(RUST_WORKSPACE_PREFIX) rustup target add aarch64-apple-darwin; \
		$(RUST_CARGO) build -p $(RUST_BIN_PACKAGE) --release --target aarch64-apple-darwin; \
	fi
	@mkdir -p "$(RUST_TARGET_DIR)/darwin-arm64"
	@if [[ "$(RUST_HOST_TARGET)" == "aarch64-apple-darwin" ]]; then \
		cp "$(RUST_TARGET_DIR)/release/orbitdock" "$(RUST_TARGET_DIR)/darwin-arm64/orbitdock"; \
	else \
		cp "$(RUST_TARGET_DIR)/aarch64-apple-darwin/release/orbitdock" "$(RUST_TARGET_DIR)/darwin-arm64/orbitdock"; \
	fi
	@chmod +x "$(RUST_TARGET_DIR)/darwin-arm64/orbitdock"
	@./scripts/server-source-fingerprint.sh > "$(RUST_TARGET_DIR)/darwin-arm64/orbitdock.gitsha"

rust-install-local: rust-build
	@set -euo pipefail; \
	mkdir -p "$(ORBITDOCK_INSTALL_ROOT)/bin"; \
	staged_bin="$$(mktemp "$(ORBITDOCK_INSTALL_ROOT)/bin/.orbitdock.XXXXXX")"; \
	cp "$(RUST_TARGET_DIR)/debug/orbitdock" "$$staged_bin"; \
	chmod 755 "$$staged_bin"; \
	mv -f "$$staged_bin" "$(ORBITDOCK_INSTALLED_BIN)"; \
	echo "Installed debug binary to $(ORBITDOCK_INSTALLED_BIN)"

rust-install-local-release: rust-build-release
	@set -euo pipefail; \
	mkdir -p "$(ORBITDOCK_INSTALL_ROOT)/bin"; \
	staged_bin="$$(mktemp "$(ORBITDOCK_INSTALL_ROOT)/bin/.orbitdock.XXXXXX")"; \
	cp "$(RUST_TARGET_DIR)/release/orbitdock" "$$staged_bin"; \
	chmod 755 "$$staged_bin"; \
	mv -f "$$staged_bin" "$(ORBITDOCK_INSTALLED_BIN)"; \
	echo "Installed release binary to $(ORBITDOCK_INSTALLED_BIN)"

rust-promote-local: rust-install-local
	@"$(ORBITDOCK_INSTALLED_BIN)" doctor

rust-check:
	$(RUST_CARGO) check -p $(RUST_BIN_PACKAGE)

rust-check-workspace:
	$(RUST_CARGO) check --workspace

rust-test:
	cd $(RUST_WORKSPACE_DIR) && RUST_MIN_STACK=8388608 $(RUST_ENV) cargo test --workspace -- --test-threads=1

rust-fmt:
	$(RUST_CARGO) fmt --all

rust-fmt-check:
	$(RUST_CARGO) fmt --all -- --check

rust-lint:
	$(RUST_CARGO) clippy --workspace --all-targets -- -D warnings

rust-run:
	$(call run_rust_start,$(RUST_CARGO),--bind $(RUST_RUN_BIND))

rust-run-lan:
	$(call run_rust_start,$(RUST_CARGO),--bind $(RUST_RUN_LAN_BIND))

rust-run-debug:
	$(call run_rust_start,cd $(RUST_WORKSPACE_DIR) && $(RUST_ENV) ORBITDOCK_SERVER_LOG_FILTER=debug cargo,)

rust-generate-token:
	$(RUST_CARGO) run -p $(RUST_BIN_PACKAGE) -- generate-token

cli:
	$(RUST_ENV) "$(RUST_TARGET_DIR)/debug/orbitdock" $(ARGS)

rust-release-darwin: web-build
	$(call package_release,darwin,)

rust-release-linux: web-build
	$(call package_release,linux,)

rust-release-linux-all: rust-release-linux-x86_64 rust-release-linux-aarch64

rust-release-linux-x86_64: web-build
	$(call package_release,linux-x86_64,)

rust-release-linux-aarch64: web-build
	$(call package_release,linux-aarch64,ORBITDOCK_LINUX_PROFILE_PRESET=$(LINUX_AARCH64_PROFILE_PRESET) ORBITDOCK_LINUX_DOCKER_CARGO_BUILD_JOBS=$(LINUX_AARCH64_DOCKER_JOBS))

rust-release-linux-smoke: rust-release-linux-smoke-x86_64 rust-release-linux-smoke-aarch64

rust-release-linux-smoke-x86_64: web-build
	$(call package_release,linux-x86_64,ORBITDOCK_LINUX_PROFILE_PRESET=smoke)

rust-release-linux-smoke-aarch64: web-build
	$(call package_release,linux-aarch64,ORBITDOCK_LINUX_PROFILE_PRESET=smoke)

rust-release-linux-test:
	$(call smoke_linux_zip,x86_64,linux/amd64)
	$(call smoke_linux_zip,aarch64,linux/arm64)

rust-release-linux-validate: rust-release-linux-smoke rust-release-linux-test

rust-clean:
	$(RUST_CARGO) clean

rust-clean-debug:
	$(RUST_CARGO) clean --profile dev
	$(RUST_CARGO) clean --profile test

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
	@if [[ "$(RUST_HOST_TARGET)" == "aarch64-apple-darwin" ]]; then \
		rm -rf "$(RUST_TARGET_DIR)/release" "$(RUST_TARGET_DIR)/aarch64-apple-darwin"; \
	else \
		$(RUST_CARGO) clean --profile release --target aarch64-apple-darwin; \
	fi
	@rm -rf "$(RUST_TARGET_DIR)/darwin-arm64" "$(RUST_TARGET_DIR)/universal"

rust-clean-release-linux-x86_64:
	$(RUST_CARGO) clean --profile release --target x86_64-unknown-linux-gnu

rust-clean-release-linux-aarch64:
	$(RUST_CARGO) clean --profile release --target aarch64-unknown-linux-gnu

rust-clean-release: rust-clean-release-darwin rust-clean-release-linux-x86_64 rust-clean-release-linux-aarch64
