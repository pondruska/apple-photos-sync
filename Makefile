APP     := ApplePhotosSync.app
BIN     := $(APP)/Contents/MacOS/apple-photos-sync
SOURCES := Sources/main.swift
# swiftc defaults the deployment target to the toolchain's own SDK, which can be
# newer than the running system — LaunchServices then refuses the bundle with
# -10825. Pin it to the oldest macOS the source supports (PHContentEditingOutput
# .supportedRenderedContentTypes needs 14). MACOSX_DEPLOYMENT_TARGET is ignored
# by swiftc, so it has to go through -target.
TARGET  := $(shell uname -m)-apple-macos14.0

.PHONY: all clean

all: $(BIN)

$(BIN): $(SOURCES) Info.plist
	@mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/Info.plist
	swiftc -O -swift-version 5 -target $(TARGET) \
		-framework Photos -framework ImageIO -framework CoreGraphics \
		-o $(BIN) $(SOURCES)
	@# Ad-hoc signature: enough for TCC to grant Photos access to the bundle.
	@# Rebuilding changes the code hash, which can require re-granting access.
	codesign --force --sign - --identifier com.ondruska.apple-photos-sync $(APP)
	@echo "built $(BIN)"

clean:
	rm -rf $(APP)
