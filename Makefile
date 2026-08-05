# AEasy Display — `make` shows available targets
SHARE  := $(HOME)/.local/share/aeasy
BIN    := $(HOME)/.local/bin
GRADLE ?= $(shell command -v gradle 2>/dev/null || echo /opt/homebrew/opt/gradle@8/bin/gradle)
# Without an explicit target swiftc builds against the host SDK version (minos 26.0),
# so the README's "macOS 13+" would not launch there and newer-than-13 APIs compile silently.
SWIFTC := swiftc -O -target $(shell uname -m)-apple-macos13.0
export ANDROID_HOME ?= $(HOME)/Library/Android/sdk
ifeq ($(wildcard $(ANDROID_HOME)),)
export ANDROID_HOME := /opt/homebrew/share/android-commandlinetools
endif

.DEFAULT_GOAL := help
.PHONY: help build apk check smoke install install-app run start stop status clean

help: ## show this help
	@echo "AEasy Display — targets:"
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-13s %s\n", $$1, $$2}'

build: mac/aeasy-server mac/aeasy-config mac/aeasy-tray ## build the macOS binaries

# multi-file swiftc allows top-level code only in a file literally named main.swift
mac/aeasy-server: mac/AEasyServer.swift mac/Protocol.swift mac/virtual-display.h
	cd mac && ln -sf AEasyServer.swift main.swift && $(SWIFTC) -import-objc-header virtual-display.h -o aeasy-server Protocol.swift main.swift; r=$$?; rm -f mac/main.swift main.swift; exit $$r

mac/aeasy-config: mac/AEasyConfig.swift
	cd mac && $(SWIFTC) -o aeasy-config AEasyConfig.swift

mac/aeasy-tray: mac/AEasyTray.swift
	cd mac && $(SWIFTC) -o aeasy-tray AEasyTray.swift

apk: ## build the Android viewer app (needs Android SDK)
	cd android && $(GRADLE) :app:assembleDebug
	@echo "APK: android/app/build/outputs/apk/debug/app-debug.apk"

mac/check: mac/Protocol.swift mac/check.swift
	cd mac && $(SWIFTC) -o check Protocol.swift check.swift

check: mac/check ## run the protocol assertions (pure, no permissions — this is the CI gate)
	./mac/check

smoke: mac/aeasy-server ## run the end-to-end smoke test (needs Screen Recording granted)
	python3 test/smoke.py

install: ## build everything + install the `aeasy` CLI (alias `aez`)
	./install.sh

install-app: ## install the APK onto the plugged-in phone
	$(BIN)/aeasy install-app

run: install ## rebuild, reinstall, then (re)start the stream
	$(BIN)/aeasy restart || $(BIN)/aeasy start

start: ## start the display + cable watcher
	$(BIN)/aeasy start

stop: ## stop everything
	$(BIN)/aeasy stop

status: ## show cable/server/app status
	$(BIN)/aeasy status

clean: ## remove build artifacts
	rm -f mac/aeasy-server mac/aeasy-config mac/aeasy-tray mac/check mac/check
	rm -rf android/app/build android/.gradle android/build
