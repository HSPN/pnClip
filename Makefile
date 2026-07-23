APP := build/PNClip.app
EXECUTABLE := $(APP)/Contents/MacOS/PNClip
SIGNING_DIR := /private/tmp/pnclip-signing-$(shell id -u)-$(shell uuidgen)
SIGNING_APP := $(SIGNING_DIR)/PNClip.app

.PHONY: all sign run clean

all: sign

$(EXECUTABLE): PNClip/main.mm PNClip/Info.plist
	mkdir -p $(APP)/Contents/MacOS
	cp PNClip/Info.plist $(APP)/Contents/Info.plist
	clang++ -std=c++17 -fobjc-arc -framework AppKit -framework ApplicationServices -framework CoreGraphics -framework CoreImage -framework CoreMedia -framework ImageIO -framework ScreenCaptureKit -framework UniformTypeIdentifiers PNClip/main.mm -o $(EXECUTABLE)

sign: $(EXECUTABLE)
	rm -rf $(SIGNING_DIR)
	mkdir -p $(SIGNING_DIR)
	ditto $(APP) $(SIGNING_APP)
	xattr -cr $(SIGNING_APP)
	codesign --force --deep --timestamp=none --sign "PNClip Development" --identifier com.example.PNClip $(SIGNING_APP)
	rm -rf $(APP)
	ditto $(SIGNING_APP) $(APP)
	xattr -cr $(APP)
	rm -rf $(SIGNING_DIR)

run: all
	open $(APP)

clean:
	rm -rf build
