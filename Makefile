APP := build/PNClip.app
EXECUTABLE := $(APP)/Contents/MacOS/PNClip
SOURCES := $(shell find PNClip -name '*.mm' -print)
SIGNING_DIR := /private/tmp/pnclip-signing-$(shell id -u)-$(shell uuidgen)
SIGNING_APP := $(SIGNING_DIR)/PNClip.app
SIGNING_CERTIFICATE := PNClip Development
SIGNING_IDENTITY ?= $(shell /usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep -Fq '"$(SIGNING_CERTIFICATE)"' && printf '%s' '$(SIGNING_CERTIFICATE)' || printf '%s' '-')

.PHONY: all sign run clean

all: sign

$(EXECUTABLE): $(SOURCES) PNClip/Info.plist PNClip/AppIcon.icns
	mkdir -p $(APP)/Contents/MacOS
	mkdir -p $(APP)/Contents/Resources
	cp PNClip/Info.plist $(APP)/Contents/Info.plist
	cp PNClip/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	clang++ -std=c++17 -fobjc-arc -framework AppKit -framework ApplicationServices -framework CoreGraphics -framework CoreImage -framework CoreMedia -framework ImageIO -framework ScreenCaptureKit -framework ServiceManagement -framework UniformTypeIdentifiers $(SOURCES) -o $(EXECUTABLE)

sign: $(EXECUTABLE)
	@if [ "$(SIGNING_IDENTITY)" = "-" ]; then \
		echo "PNClip Development 인증서가 없어 ad-hoc 서명을 사용합니다."; \
	else \
		echo "$(SIGNING_IDENTITY) 인증서로 서명합니다."; \
	fi
	rm -rf $(SIGNING_DIR)
	mkdir -p $(SIGNING_DIR)
	ditto $(APP) $(SIGNING_APP)
	xattr -cr $(SIGNING_APP)
	codesign --force --deep --timestamp=none --sign "$(SIGNING_IDENTITY)" --identifier com.example.PNClip $(SIGNING_APP)
	rm -rf $(APP)
	ditto $(SIGNING_APP) $(APP)
	xattr -cr $(APP)
	rm -rf $(SIGNING_DIR)

run: all
	open $(APP)

clean:
	rm -rf build
