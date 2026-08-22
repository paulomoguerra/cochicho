EXEC     := EkoNami
CONFIG   := release

## Build products and the assembled .app live OUTSIDE this directory: file-provider-synced
## folders mutate files mid-compile ("input file was modified during the build") and
## re-stamp com.apple.FinderInfo faster than xattr -cr can strip it, which makes codesign
## refuse. ~/Library/Caches is never synced.
SCRATCH  := $(HOME)/Library/Caches/EkoNamiBuild/scratch
BUILD    := $(SCRATCH)/$(CONFIG)/$(EXEC)
STAGE    := $(HOME)/Library/Caches/EkoNamiBuild
APPNAME  := Eko Nami.app
BUNDLE   := $(STAGE)/$(APPNAME)
CONTENTS := $(BUNDLE)/Contents

## TCC keys the Accessibility grant to the code signature; an ad-hoc signature changes on
## every build and silently invalidates the grant. Any stable identity fixes that:
## prefer Developer ID (distribution), then Apple Development (free, local-only),
## fall back to ad-hoc only when the machine has neither.
## Sign by SHA-1 hash, not name — duplicate certificates with identical names make
## codesign refuse with "ambiguous".
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
             | grep "Developer ID Application" | head -1 | awk '{print $$2}')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
             | grep "Apple Development" | head -1 | awk '{print $$2}')
endif
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

.PHONY: all build app run install icon clean

all: app

build:
	swift build -c $(CONFIG) --scratch-path "$(SCRATCH)"

icon:
	@swift Support/makeicon.swift
	@iconutil -c icns Support/AppIcon.iconset -o Support/AppIcon.icns
	@echo "wrote Support/AppIcon.icns"

## Assemble a real .app bundle — TCC (microphone + Accessibility) keys on bundle identity
## and code signature, so the raw SwiftPM binary can't be used directly.
app: build
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(BUILD)" "$(CONTENTS)/MacOS/$(EXEC)"
	@cp Support/Info.plist "$(CONTENTS)/Info.plist"
	@if [ -f Support/AppIcon.icns ]; then cp Support/AppIcon.icns "$(CONTENTS)/Resources/"; fi
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@xattr -cr "$(BUNDLE)"
	@codesign --force --sign "$(SIGN_ID)" \
		--entitlements Support/$(EXEC).entitlements \
		--options runtime \
		--timestamp=none \
		"$(BUNDLE)"
	@echo "built $(BUNDLE)  [signed: $(SIGN_ID)]"

run: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@open "$(BUNDLE)"

## Installing to /Applications keeps the path stable, so re-granting TCC (needed after
## ad-hoc re-signs) is a one-click fix instead of a hunt.
install: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@rm -rf "/Applications/$(APPNAME)"
	@cp -R "$(BUNDLE)" "/Applications/$(APPNAME)"
	@open "/Applications/$(APPNAME)"

clean:
	rm -rf "$(STAGE)"
