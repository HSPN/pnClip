APP := build/PNClip.app
EXECUTABLE := $(APP)/Contents/MacOS/PNClip
MAC_SOURCES := $(shell find PNClip -name '*Mac.mm' -print)
MAC_SOURCES := $(filter-out PNClip/Formats/GIF/GIFColorQuantizerMac.mm PNClip/Formats/GIF/GIFDithererMac.mm PNClip/Formats/GIF/GIFLZWEncoderMac.mm,$(MAC_SOURCES))
COMMON_SOURCES := $(shell find PNClip/Core -name '*.cpp' -print)
SOURCES := $(MAC_SOURCES) $(COMMON_SOURCES)
WEBP_INCLUDE := ThirdParty/libwebp/include
WEBP_LIBS := ThirdParty/libwebp/lib/libwebpmux.a ThirdParty/libwebp/lib/libwebp.a ThirdParty/libwebp/lib/libsharpyuv.a
SIGNING_DIR := /private/tmp/pnclip-signing-$(shell id -u)-$(shell uuidgen)
SIGNING_APP := $(SIGNING_DIR)/PNClip.app
SIGNING_CERTIFICATE := PNClip Development

.PHONY: all build sign run test test-core test-platform-contract test-gif test-webp windows windows-configure clean

all: sign

build: $(EXECUTABLE)

$(EXECUTABLE): $(SOURCES) PNClip/Info.plist PNClip/AppIcon.icns
	mkdir -p $(APP)/Contents/MacOS
	mkdir -p $(APP)/Contents/Resources
	cp PNClip/Info.plist $(APP)/Contents/Info.plist
	cp PNClip/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp ThirdParty/libwebp/COPYING $(APP)/Contents/Resources/libwebp-COPYING.txt
	cp ThirdParty/libwebp/PATENTS $(APP)/Contents/Resources/libwebp-PATENTS.txt
	clang++ -std=c++20 -fobjc-arc -I$(WEBP_INCLUDE) -framework AppKit -framework ApplicationServices -framework CoreGraphics -framework CoreImage -framework CoreMedia -framework ImageIO -framework ScreenCaptureKit -framework ServiceManagement -framework UniformTypeIdentifiers $(SOURCES) $(WEBP_LIBS) -o $(EXECUTABLE)

sign: $(EXECUTABLE)
	Scripts/sign-app.sh "$(APP)" "$(SIGNING_DIR)" "$(SIGNING_CERTIFICATE)"

run: all
	open $(APP)

test: test-core test-platform-contract test-gif test-webp

test-core:
	clang++ -std=c++20 -I$(WEBP_INCLUDE) Tests/CoreTests.cpp $(COMMON_SOURCES) $(WEBP_LIBS) -o /tmp/pnclip-core-tests
	/tmp/pnclip-core-tests

test-platform-contract:
	clang++ -std=c++20 -fsyntax-only PNClip/Capture/CaptureBackendWin.cpp PNClip/Support/PlatformServicesWin.cpp

test-gif:
	clang++ -std=c++20 -fobjc-arc -framework AppKit -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers Tests/GIFEncoderTests.mm PNClip/Formats/GIF/GIFEncoderMac.mm PNClip/Core/GifEncoder.cpp PNClip/Core/GifLzwEncoder.cpp PNClip/Core/CaptureTypes.cpp -o /tmp/pnclip-gif-encoder-tests
	/tmp/pnclip-gif-encoder-tests
	@if command -v ffmpeg >/dev/null 2>&1; then ffmpeg -v error -i /tmp/pnclip-gif-encoder-test.gif -f null -; fi

test-webp:
	clang++ -std=c++20 -fobjc-arc -I$(WEBP_INCLUDE) -framework AppKit -framework CoreGraphics -framework ImageIO Tests/WebPEncoderTests.mm PNClip/Formats/WebP/WebPEncoderMac.mm PNClip/Core/WebPEncoder.cpp PNClip/Core/CaptureTypes.cpp $(WEBP_LIBS) -o /tmp/pnclip-webp-encoder-tests
	/tmp/pnclip-webp-encoder-tests

windows-configure:
	cmake -S . -B build/windows -DPNCLIP_BUILD_WINDOWS=ON

windows: windows-configure
	cmake --build build/windows --config Release

clean:
	rm -rf build
