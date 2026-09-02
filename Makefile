EXEC     := Sotto
APPNAME  := Sotto.app
CONFIG   := debug

# Build products and the staged bundle live outside the repo. This keeps the tree clean
# and avoids ever building inside a cloud-synced folder, where a sync engine can touch
# object files mid-compile or stamp extended attributes onto the bundle that codesign
# refuses.
#
# A linked worktree (`.git` is a file, not a directory) gets its own stage under
# worktrees/<name>, so parallel builds never share SwiftPM state or clobber each other's
# bundle. Only the main checkout owns the canonical stage, and only the canonical stage may
# be launched or installed: every opened copy of Sotto.app registers itself with
# LaunchServices under the same bundle id, and while the Accessibility grant is missing
# each one pops the system prompt.
CANONICAL_STAGE := $(HOME)/Library/Caches/SottoBuild
IS_WORKTREE     := $(shell test -f .git && echo 1)
ifeq ($(IS_WORKTREE),1)
STAGE    := $(CANONICAL_STAGE)/worktrees/$(notdir $(CURDIR))
else
STAGE    := $(CANONICAL_STAGE)
endif
SCRATCH    := $(STAGE)/scratch
BUILD      := $(SCRATCH)/$(CONFIG)/$(EXEC)
BUNDLE     := $(STAGE)/$(APPNAME)
CONTENTS   := $(BUNDLE)/Contents
INSTALLED  := /Applications/$(APPNAME)
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# TCC keys the Accessibility and Microphone grants to the code signature. An ad-hoc
# signature changes on every build, which silently invalidates the grant while the toggle
# in System Settings still shows as on. A Developer ID keeps the identity stable across
# rebuilds, so `app` refuses to sign without one instead of falling back. SIGN_ID=- on
# the command line forces a throwaway ad-hoc build; it will prompt again on every rebuild.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
	         | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')

.PHONY: all build test app run install clean icon signing-identity launchable

all: app

build:
	swift build -c $(CONFIG) --scratch-path "$(SCRATCH)"

test:
	swift test --scratch-path "$(SCRATCH)"

signing-identity:
	@if [ -z "$(strip $(SIGN_ID))" ]; then \
	    echo "error: no Developer ID Application identity in the keychain; refusing to sign ad-hoc." >&2; \
	    echo "       An ad-hoc signature changes every build and resets the Accessibility grant." >&2; \
	    echo "       Unlock the login keychain and retry, or pass SIGN_ID=- for a throwaway build." >&2; \
	    exit 1; \
	fi

# Launching and installing are allowed only from the main checkout's canonical stage.
launchable:
	@if [ "$(STAGE)" != "$(CANONICAL_STAGE)" ]; then \
	    echo "error: run and install work only from the main checkout with the default STAGE." >&2; \
	    echo "       This is a worktree or an overridden STAGE: build and test here, launch from the main checkout." >&2; \
	    exit 1; \
	fi

# TCC needs a real bundle with a stable identifier; the bare SwiftPM binary is not enough.
app: signing-identity build
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

run: launchable app
	@pkill -x $(EXEC) 2>/dev/null || true
	@open "$(BUNDLE)"

# The staged copy is unregistered afterwards so LaunchServices resolves the bundle id to
# the installed app alone. lsregister -u exits 1 (-10814) when the path was never
# registered, which is the normal case after a plain `make app`, hence the `|| true`.
install: launchable app
	@pkill -x $(EXEC) 2>/dev/null || true
	@rm -rf "$(INSTALLED)"
	@cp -R "$(BUNDLE)" "$(INSTALLED)"
	@"$(LSREGISTER)" -u "$(BUNDLE)" >/dev/null 2>&1 || true
	@"$(LSREGISTER)" -f "$(INSTALLED)"
	@open "$(INSTALLED)"
	@echo "installed to $(INSTALLED)"

## Regenerates the app icon from Tools/makeicon.swift. Not a dependency of `app`: the icon
## rarely changes and rendering ten PNGs on every build is wasted time.
## After changing the icon, bump CFBundleVersion in Resources/Info.plist: the icon service
## caches per bundle identity and version, and the Dock keeps the old tile otherwise.
icon:
	@swift Tools/makeicon.swift
	@iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "wrote Resources/AppIcon.icns"

# From the main checkout this also removes every worktree stage under $(STAGE)/worktrees.
clean:
	@if [ -d "$(BUNDLE)" ]; then "$(LSREGISTER)" -u "$(BUNDLE)" >/dev/null 2>&1 || true; fi
	@rm -rf .build "$(STAGE)"
