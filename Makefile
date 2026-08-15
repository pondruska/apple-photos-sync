APP     := ApplePhotosSync.app
BIN     := $(APP)/Contents/MacOS/apple-photos-sync
SOURCES := Sources/main.swift

.PHONY: all clean

all: $(BIN)

$(BIN): $(SOURCES) Info.plist
	@mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/Info.plist
	swiftc -O -swift-version 5 \
		-framework Photos -framework ImageIO -framework CoreGraphics \
		-o $(BIN) $(SOURCES)
	@# Ad-hoc signature: enough for TCC to grant Photos access to the bundle.
	@# Rebuilding changes the code hash, which can require re-granting access.
	codesign --force --sign - --identifier com.ondruska.apple-photos-sync $(APP)
	@echo "built $(BIN)"

clean:
	rm -rf $(APP)
