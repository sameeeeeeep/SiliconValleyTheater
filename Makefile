APP_NAME = SiliconValleyTheater
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
SOURCES = $(shell find Sources -name '*.swift')

.PHONY: build run clean

build: $(APP_BUNDLE)

$(APP_BUNDLE): $(SOURCES)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	swiftc \
		-swift-version 5 \
		-target arm64-apple-macosx14.0 \
		-sdk $(shell xcrun --show-sdk-path) \
		-parse-as-library \
		-o $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME) \
		$(SOURCES)
	@cp Resources/default_config.json $(APP_BUNDLE)/Contents/Resources/ 2>/dev/null || true
	@/usr/bin/env python3 -c "open('$(APP_BUNDLE)/Contents/Info.plist','w').write('<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict><key>CFBundleName</key><string>SiliconValley Theater</string><key>CFBundleIdentifier</key><string>com.siliconvalley.theater</string><key>CFBundleExecutable</key><string>$(APP_NAME)</string><key>CFBundleVersion</key><string>1.0</string><key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict></dict></plist>')"
	@codesign --force --sign - $(APP_BUNDLE) 2>/dev/null || true
	@echo "Built: $(APP_BUNDLE)"

run: build
	open $(APP_BUNDLE)

clean:
	rm -rf $(BUILD_DIR)
