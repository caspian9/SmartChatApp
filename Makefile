# Pick the first available, non-simulator iOS device, by name.
# Name works for both xcodebuild -destination and devicectl --device,
# avoiding the CoreDevice-vs-device-UDID mismatch between the two APIs.
DEVICE_NAME := $(shell xcrun xcdevice list 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((x['name'] for x in d if not x.get('simulator') and x.get('available') and x.get('platform') == 'com.apple.platform.iphoneos'), ''))" 2>/dev/null)

.PHONY: build install list-devices compile-only install-only

build:
	xcodegen generate
	xcodebuild -skipMacroValidation -scheme SmartChatApp \
		-destination "platform=iOS,name=$(DEVICE_NAME)" \
		-allowProvisioningUpdates build

# Like build, but skips code signing and uses a generic iOS destination —
# runs with no device connected. Useful on a machine without an Apple ID /
# provisioning profile, or for a quick syntax check. Output is in DerivedData
# but .app is not installable (no provisioning profile).
compile-only:
	xcodegen generate
	xcodebuild -skipMacroValidation -scheme SmartChatApp \
		-destination 'generic/platform=iOS' \
		CODE_SIGNING_ALLOWED=NO build

install: build
	xcrun devicectl device install app --device "$(DEVICE_NAME)" \
		~/Library/Developer/Xcode/DerivedData/SmartChatApp-*/Build/Products/Debug-iphoneos/SmartChatApp.app

# Install a previously-built .app from DerivedData without re-running build.
# Useful for re-installing after a device reboot or for quick iteration when
# the binary hasn't changed.
APP_PATH := $(HOME)/Library/Developer/Xcode/DerivedData/SmartChatApp-*/Build/Products/Debug-iphoneos/SmartChatApp.app
install-only:
	@ls -d $(APP_PATH) >/dev/null 2>&1 || { echo "❌ No built .app found at $(APP_PATH). Run 'make build' first."; exit 1; }
	xcrun devicectl device install app --device "$(DEVICE_NAME)" $(APP_PATH)

list-devices:
	@echo "=== make build will target (xcdevice, xcodebuild-compatible) ==="
	@xcrun xcdevice list 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); [print(f\"  {'*' if not x.get('simulator') and x.get('available') and x.get('platform') == 'com.apple.platform.iphoneos' else ' '} {x.get('name'):<30}  {x.get('identifier')}\") for x in d if not x.get('simulator')]" 2>/dev/null
	@echo ""
	@echo "=== Connected iOS devices (devicectl) ==="
	@xcrun devicectl list devices 2>&1 | tail -n +3
