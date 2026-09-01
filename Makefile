EXEC     := Sotto
APPNAME  := Sotto.app
CONFIG   := debug

# Build products and the staged bundle live outside the repo. This keeps the tree clean
# and avoids ever building inside a cloud-synced folder, where a sync engine can touch
# object files mid-compile or stamp extended attributes onto the bundle that codesign
# refuses.
STAGE    := $(HOME)/Library/Caches/SottoBuild
SCRATCH  := $(STAGE)/scratch
BUILD    := $(SCRATCH)/$(CONFIG)/$(EXEC)
BUNDLE   := $(STAGE)/$(APPNAME)
CONTENTS := $(BUNDLE)/Contents

# TCC keys the Accessibility and Microphone grants to the code signature. An ad-hoc
# signature changes on every build, which silently invalidates the grant while the toggle
# in System Settings still shows as on. A Developer ID keeps the identity stable across
# rebuilds. Falls back to ad-hoc on a machine without one.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
	         | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

.PHONY: all build test app run install clean

all: app

build:
	swift build -c $(CONFIG) --scratch-path "$(SCRATCH)"

test:
	swift test --scratch-path "$(SCRATCH)"

# TCC needs a real bundle with a stable identifier; the bare SwiftPM binary is not enough.
app: build
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(BUILD)" "$(CONTENTS)/MacOS/$(EXEC)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"; fi
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@xattr -cr "$(BUNDLE)"
	@codesign --force --sign "$(SIGN_ID)" \
	    --entitlements Resources/$(EXEC).entitlements \
	    --options runtime \
	    --timestamp=none \
	    "$(BUNDLE)"
	@echo "built $(BUNDLE)  [signed: $(SIGN_ID)]"

run: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@open "$(BUNDLE)"

install: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@rm -rf "/Applications/$(APPNAME)"
	@cp -R "$(BUNDLE)" "/Applications/$(APPNAME)"
	@open "/Applications/$(APPNAME)"
	@echo "installed to /Applications/$(APPNAME)"

clean:
	@rm -rf .build "$(STAGE)"
