CC ?= cc
CFLAGS ?= -std=c11 -O2
CFLAGS += -Wall -Wextra -Wpedantic -Werror
PREFIX ?= /usr/local
CHROME_EXTENSION_SRC := chrome-redmine-links
CHROME_EXTENSION_DIST := dist/chrome-redmine-links
UPDATER_APP_NAME := Worktree Target Branch Updater
UPDATER_APP := dist/$(UPDATER_APP_NAME).app
UPDATER_CONTENTS := $(UPDATER_APP)/Contents
UNAME := $(shell uname -s)
OCR_DIR := third_party/open-code-review
OCR_VERSION := $(shell cat $(OCR_DIR)/VERSION)
OCR_SOURCES := $(shell find $(OCR_DIR) -type f)

.PHONY: all clean install test macos-app chrome-extension-build

all: mrsk dist/ocr

mrsk: src/mrsk.c
	$(CC) $(CFLAGS) -o $@ $<

dist/ocr: $(OCR_SOURCES)
	install -d dist
	CGO_ENABLED=0 go -C $(OCR_DIR) build \
		-ldflags "-s -w -X main.Version=$(OCR_VERSION)" -o "$(CURDIR)/$@" ./cmd/opencodereview

macos-app: mrsk worktree-target-branch-updater macos/Info.plist assets/WorktreeTargetBranchUpdater.icns
	install -d "$(UPDATER_CONTENTS)/MacOS" "$(UPDATER_CONTENTS)/Resources"
	install -m 0755 mrsk "$(UPDATER_CONTENTS)/MacOS/$(UPDATER_APP_NAME)"
	install -m 0755 worktree-target-branch-updater "$(UPDATER_CONTENTS)/Resources/worktree-target-branch-updater"
	install -m 0644 macos/Info.plist "$(UPDATER_CONTENTS)/Info.plist"
	install -m 0644 assets/WorktreeTargetBranchUpdater.icns "$(UPDATER_CONTENTS)/Resources/WorktreeTargetBranchUpdater.icns"
	codesign --force --deep --sign - "$(UPDATER_APP)"

ifeq ($(UNAME),Darwin)
install: macos-app dist/ocr
else
install: mrsk worktree-target-branch-updater dist/ocr
endif
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 0755 mrsk "$(DESTDIR)$(PREFIX)/bin/mrsk"
	install -m 0755 dist/ocr "$(DESTDIR)$(PREFIX)/bin/ocr"
ifeq ($(UNAME),Darwin)
	install -d "$(DESTDIR)$(PREFIX)/libexec/$(UPDATER_APP_NAME).app/Contents/MacOS" \
		"$(DESTDIR)$(PREFIX)/libexec/$(UPDATER_APP_NAME).app/Contents/Resources"
	install -m 0755 mrsk "$(DESTDIR)$(PREFIX)/libexec/$(UPDATER_APP_NAME).app/Contents/MacOS/$(UPDATER_APP_NAME)"
	install -m 0755 worktree-target-branch-updater \
		"$(DESTDIR)$(PREFIX)/libexec/$(UPDATER_APP_NAME).app/Contents/Resources/worktree-target-branch-updater"
	install -m 0644 macos/Info.plist \
		"$(DESTDIR)$(PREFIX)/libexec/$(UPDATER_APP_NAME).app/Contents/Info.plist"
	install -m 0644 assets/WorktreeTargetBranchUpdater.icns \
		"$(DESTDIR)$(PREFIX)/libexec/$(UPDATER_APP_NAME).app/Contents/Resources/WorktreeTargetBranchUpdater.icns"
	codesign --force --deep --sign - \
		"$(DESTDIR)$(PREFIX)/libexec/$(UPDATER_APP_NAME).app"
	ln -sf "../libexec/$(UPDATER_APP_NAME).app/Contents/Resources/worktree-target-branch-updater" \
		"$(DESTDIR)$(PREFIX)/bin/worktree-target-branch-updater"
	rm -f "$(DESTDIR)$(PREFIX)/bin/work-daemon"
	@if [ -z "$(DESTDIR)" ]; then \
		/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
			-f "$(PREFIX)/libexec/$(UPDATER_APP_NAME).app"; \
	fi
else
	install -m 0755 worktree-target-branch-updater "$(DESTDIR)$(PREFIX)/bin/worktree-target-branch-updater"
endif

ifeq ($(UNAME),Darwin)
test: macos-app dist/ocr
else
test: mrsk dist/ocr
endif
	MRSK_BIN="$(CURDIR)/mrsk" tests/e2e.sh
	MRSK_BIN="$(CURDIR)/mrsk" tests/clone_e2e.sh
	MRSK_BIN="$(CURDIR)/mrsk" tests/missing_copy_sources_e2e.sh
	MRSK_BIN="$(CURDIR)/mrsk" tests/database_e2e.sh
ifeq ($(UNAME),Darwin)
	MRSK_BIN="$(CURDIR)/mrsk" tests/updater_e2e.sh
endif
	MRSK_BIN="$(CURDIR)/mrsk" OCR_BIN="$(CURDIR)/dist/ocr" tests/review_e2e.sh

chrome-extension-build:
	node -e 'require("./$(CHROME_EXTENSION_SRC)/manifest.json")'
	node "$(CHROME_EXTENSION_SRC)/test.cjs"
	rm -rf "$(CHROME_EXTENSION_DIST)"
	install -d "$(CHROME_EXTENSION_DIST)"
	install -m 0644 "$(CHROME_EXTENSION_SRC)/manifest.json" "$(CHROME_EXTENSION_SRC)/content.js" \
		"$(CHROME_EXTENSION_SRC)/options.html" "$(CHROME_EXTENSION_SRC)/options.js" \
		"$(CHROME_EXTENSION_SRC)/redmine.js" "$(CHROME_EXTENSION_DIST)/"

clean:
	rm -rf mrsk dist
