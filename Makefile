# Pick the first available, non-simulator iOS device, by name.
# Name works for both xcodebuild -destination and devicectl --device,
# avoiding the CoreDevice-vs-device-UDID mismatch between the two APIs.
DEVICE_NAME := $(shell xcrun xcdevice list 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((x['name'] for x in d if not x.get('simulator') and x.get('available') and x.get('platform') == 'com.apple.platform.iphoneos'), ''))" 2>/dev/null)

# Remote-build config. Default REMOTE_CONFIG_PATH lives in config/RemoteBuild.mk;
# personal override goes in config/LocalRemoteBuild.mk (gitignored). Pattern
# parallels config/Signing.xcconfig + config/LocalSigning.xcconfig.
include config/RemoteBuild.mk
-include config/LocalRemoteBuild.mk

.PHONY: build install install-remote list-devices compile-only install-only configure-signing detect-team clean-signing inject-build-timestamp bump-patch bump-minor bump-major

# Auto-detect the Apple Team ID and write it (plus canonical Bundle IDs) into
# config/.local-signing.xcconfig, which config/Signing.xcconfig #include?s.
# Idempotent: a second run with the same inputs is a no-op.
configure-signing:
	@bash scripts/ios-configure-signing.sh

# Print the detected Team ID without writing any file. Useful for debugging
# "make build is signing with the wrong team" issues.
detect-team:
	@bash scripts/ios-team-id.sh

# Write the current build timestamp (yyyyMMdd-HHmm) into
# config/.local-version.xcconfig, which config/Version.xcconfig #include?s.
# Idempotent: skip the write when the value is unchanged so the mtime
# (and Xcode's build cache) survives rapid rebuilds.
inject-build-timestamp:
	@bash scripts/inject-build-timestamp.sh

# Remove the local override file; the next `make build` regenerates it
# (or, if no Team is detectable, falls back to the empty shared default).
clean-signing:
	@rm -f config/.local-signing.xcconfig
	@echo "Removed config/.local-signing.xcconfig"

build: configure-signing inject-build-timestamp
	xcodegen generate
	xcodebuild -skipMacroValidation -scheme SmartChatApp \
		-destination "platform=iOS,name=$(DEVICE_NAME)" \
		-allowProvisioningUpdates build

# Build-system env overrides:
#   IOS_DEVELOPMENT_TEAM  — bypass Team-ID auto-detect; pin
#                            to a specific Apple Developer
#                            Team (10-char alphanumeric). Used
#                            by scripts/ios-team-id.sh and by
#                            the release.yml CI workflow
#                            (which sets this from a repo or
#                            org secret for tag builds).

# Auto-bump SMARTCHATAPP_MARKETING_VERSION (and project.yml mirror)
# and pre-fill the CHANGELOG. Does NOT auto-commit or auto-tag —
# review the diff first. Append --dry-run to preview.
bump-patch: ; @bash scripts/bump-version.sh patch
bump-minor: ; @bash scripts/bump-version.sh minor
bump-major: ; @bash scripts/bump-version.sh major

# Like build, but skips code signing and uses a generic iOS destination —
# runs with no device connected. Useful on a machine without an Apple ID /
# provisioning profile, or for a quick syntax check. Output is in DerivedData
# but .app is not installable (no provisioning profile).
compile-only: configure-signing inject-build-timestamp
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

# Run the full unit test suite on the iPhone 17 Pro simulator.
# Must run `xcodegen generate` first: the project's pbxproj is
# generated from project.yml's source path filter, so any new
# test file added under SmartChatAppTests/ won't be picked up
# by xcodebuild until the project is regenerated. Without
# this prerequisite, `xcodebuild test` would compile the
# existing 15 test files and silently skip the newly added
# 16th, 17th, etc. (Build 7512 incident: `MessageHeightCacheTests`
# was missing from the test run because xcodegen hadn't
# been re-run after the file was created.)
#
# The simulator destination is hardcoded to iPhone 17 Pro to
# match the simulator the project's CI uses (see
# .github/workflows/ci.yml); physical-device tests aren't
# supported (no UI testing target configured in project.yml).
test: configure-signing
	xcodegen generate
	xcodebuild test -skipMacroValidation -scheme SmartChatApp \
		-destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# install-remote: build the .app locally (signed with your Team ID),
# scp it to a remote box where the iPhone is paired, then run
# `xcrun devicectl device install app` there.
#
# Usage: make install-remote REMOTE_TARGET=<host-or-alias>
#
# Required on the remote machine:
#   ~/.config/smartchatapp/build-remote.conf (or whatever REMOTE_CONFIG_PATH
#   points to) containing REMOTE_DEVICE_NAME and REMOTE_APP_DIR, one per
#   line, KEY=VALUE format.
#
# SSH auth is key-based. If `ssh -o BatchMode=yes` fails, run `ssh-add`
# to load your key into the agent.
install-remote: build
	@if [ -z "$$REMOTE_TARGET" ]; then \
		echo "Usage: make install-remote REMOTE_TARGET=<host-or-alias>"; \
		echo "  Or set REMOTE_TARGET in config/RemoteBuild.mk for a per-checkout default."; \
		echo "  CLI args override config/ values."; \
		exit 1; \
	fi
	@REMOTE_TARGET='$$REMOTE_TARGET' \
	 REMOTE_CONFIG_PATH='$$REMOTE_CONFIG_PATH' \
	 bash scripts/install-remote.sh
