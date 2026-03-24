.PHONY: \
	build build-ios build-all run-ios-device clean test-all test-unit test-unit-ios test-ui \
	fmt lint swift-fmt swift-lint xcode-cache-dirs

build:
	$(call run_xcode_logged,$(XCODEBUILD_MACOS) build,xcodebuild-build.log)

build-ios:
	$(call run_xcode_logged,$(XCODEBUILD_IOS) build,xcodebuild-build-ios.log)

build-all: build build-ios

run-ios-device:
	@$(MAKE) xcode-cache-dirs
	@mkdir -p $(XCODEBUILD_LOG_DIR)
	@set -euo pipefail; \
	device_name="$${DEVICE:-$(XCODE_IOS_DEVICE_NAME)}"; \
	device_id="$${DEVICE_ID:-$(XCODE_IOS_DEVICE_ID)}"; \
	if [[ -z "$$device_name" && -z "$$device_id" ]]; then \
		echo "Provide DEVICE='<device name>' or DEVICE_ID=<id>."; \
		exit 1; \
	fi; \
	if [[ -z "$$device_id" ]]; then \
		device_id="$$(xcrun xcdevice list | ruby -rjson -e 'devices = JSON.parse(STDIN.read); name = ARGV[0].downcase; device = devices.find { |d| !d["simulator"] && d["available"] && d["name"].to_s.downcase == name }; puts device["identifier"] if device' "$$device_name")"; \
	fi; \
	if [[ -z "$$device_id" ]]; then \
		echo "Could not resolve iOS device '$$device_name'. Pass DEVICE_ID=<id> to override."; \
		exit 1; \
	fi; \
	echo "Building for device $$device_name ($$device_id)"; \
	set -o pipefail; \
	$(XCODEBUILD_ENV) xcodebuild \
		-project $(XCODE_PROJECT) \
		-scheme "$(XCODE_IOS_SCHEME)" \
		-destination "id=$$device_id" \
		$(XCODE_IOS_DEVICE_BUILD_FLAGS) \
		$(XCODEBUILD_ARGS) \
		build 2>&1 | tee "$(XCODEBUILD_LOG_DIR)/xcodebuild-run-ios-device.log" | xcbeautify --quiet; \
	app_path="$(abspath $(XCODE_DERIVED_DATA_DIR))/Build/Products/Debug-iphoneos/OrbitDock iOS.app"; \
	if [[ ! -d "$$app_path" ]]; then \
		echo "Built app not found at $$app_path"; \
		exit 1; \
	fi; \
	echo "Installing $$app_path"; \
	xcrun devicectl device install app --device "$$device_id" "$$app_path"; \
	echo "Launching $(XCODE_IOS_DEVICE_BUNDLE_ID)"; \
	xcrun devicectl device process launch --device "$$device_id" "$(XCODE_IOS_DEVICE_BUNDLE_ID)"

test-unit:
	$(call run_xcode_pretty,$(XCODEBUILD_UNIT_TEST) -parallel-testing-enabled NO test)

test-unit-ios:
	$(call run_xcode_pretty,$(XCODEBUILD_IOS_UNIT_TEST) -parallel-testing-enabled NO -only-testing:"OrbitDock iOSTests" test)

test-ui:
	$(call run_xcode_pretty,$(XCODEBUILD_MACOS) -only-testing:OrbitDockUITests test)

test-all:
	$(call run_xcode_pretty,$(XCODEBUILD_MACOS) test)

clean:
	@$(MAKE) xcode-cache-dirs
	$(XCODEBUILD_MACOS) clean

fmt: swift-fmt rust-fmt web-fmt

lint: swift-lint rust-lint web-lint

swift-fmt:
	swiftformat OrbitDockNative

swift-lint:
	swiftformat --lint OrbitDockNative

xcode-cache-dirs:
	@mkdir -p $(XCODE_DERIVED_DATA_DIR) $(XCODE_PACKAGE_CACHE_DIR) $(XCODE_SOURCE_PACKAGES_DIR) $(XCODE_CLANG_MODULE_CACHE_DIR) $(XCODE_SWIFTPM_MODULECACHE_DIR)
