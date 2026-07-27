APP := build/PNClip.app
EXECUTABLE := $(APP)/Contents/MacOS/PNClip
SOURCES := $(shell find PNClip -name '*.mm' -print)
WEBP_INCLUDE := ThirdParty/libwebp/include
WEBP_LIBS := ThirdParty/libwebp/lib/libwebpmux.a ThirdParty/libwebp/lib/libwebp.a ThirdParty/libwebp/lib/libsharpyuv.a
SIGNING_DIR := /private/tmp/pnclip-signing-$(shell id -u)-$(shell uuidgen)
SIGNING_APP := $(SIGNING_DIR)/PNClip.app
SIGNING_CERTIFICATE := PNClip Development

.PHONY: all sign run test-gif test-webp clean

all: sign

$(EXECUTABLE): $(SOURCES) PNClip/Info.plist PNClip/AppIcon.icns
	mkdir -p $(APP)/Contents/MacOS
	mkdir -p $(APP)/Contents/Resources
	cp PNClip/Info.plist $(APP)/Contents/Info.plist
	cp PNClip/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp ThirdParty/libwebp/COPYING $(APP)/Contents/Resources/libwebp-COPYING.txt
	cp ThirdParty/libwebp/PATENTS $(APP)/Contents/Resources/libwebp-PATENTS.txt
	clang++ -std=c++17 -fobjc-arc -I$(WEBP_INCLUDE) -framework AppKit -framework ApplicationServices -framework CoreGraphics -framework CoreImage -framework CoreMedia -framework ImageIO -framework ScreenCaptureKit -framework ServiceManagement -framework UniformTypeIdentifiers $(SOURCES) $(WEBP_LIBS) -o $(EXECUTABLE)

sign: $(EXECUTABLE)
	Scripts/sign-app.sh "$(APP)" "$(SIGNING_DIR)" "$(SIGNING_CERTIFICATE)"

run: all
	open $(APP)

test-gif:
	clang++ -std=c++17 -fobjc-arc -framework AppKit -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers Tests/GIFEncoderTests.mm PNClip/Formats/GIF/GIFEncoder.mm PNClip/Formats/GIF/GIFColorQuantizer.mm PNClip/Formats/GIF/GIFDitherer.mm PNClip/Formats/GIF/GIFLZWEncoder.mm -o /tmp/pnclip-gif-encoder-tests
	/tmp/pnclip-gif-encoder-tests
	@if command -v ffmpeg >/dev/null 2>&1; then ffmpeg -v error -i /tmp/pnclip-gif-encoder-test.gif -f null -; fi

test-webp:
	clang++ -std=c++17 -fobjc-arc -I$(WEBP_INCLUDE) -framework AppKit -framework CoreGraphics -framework ImageIO Tests/WebPEncoderTests.mm PNClip/Formats/WebP/WebPEncoder.mm $(WEBP_LIBS) -o /tmp/pnclip-webp-encoder-tests
	/tmp/pnclip-webp-encoder-tests

clean:
	rm -rf build
