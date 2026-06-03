DEVICE_ID := $(shell xcrun devicectl list devices 2>/dev/null | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)

.PHONY: build install list-devices

build:
	xcodegen generate
	xcodebuild build -scheme SmartChatApp -destination "platform=iOS,id=$(DEVICE_ID)" -allowProvisioningUpdates build

install: build
	xcrun devicectl device install app --device $(DEVICE_ID) ~/Library/Developer/Xcode/DerivedData/SmartChatApp-*/Build/Products/Debug-iphoneos/SmartChatApp.app

list-devices:
	xcrun devicectl list devices