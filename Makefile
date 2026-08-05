# AEasy Display — `make` shows available targets
SHARE  := $(HOME)/.local/share/aeasy
BIN    := $(HOME)/.local/bin
GRADLE ?= $(shell command -v gradle 2>/dev/null || echo /opt/homebrew/opt/gradle@8/bin/gradle)
export ANDROID_HOME ?= $(HOME)/Library/Android/sdk
ifeq ($(wildcard $(ANDROID_HOME)),)
export ANDROID_HOME := /opt/homebrew/share/android-commandlinetools
endif

.DEFAULT_GOAL := help
.PHONY: help build apk install install-app run start stop status clean

help: ## show this help
	@echo "AEasy Display — targets:"
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-13s %s\n", $$1, $$2}'

build: mac/aeasy-server mac/aeasy-config mac/aeasy-tray ## build the macOS binaries

mac/aeasy-server: mac/AEasyServer.swift mac/virtual-display.h
	cd mac && swiftc -O -import-objc-header virtual-display.h -o aeasy-server AEasyServer.swift

mac/aeasy-config: mac/AEasyConfig.swift
	cd mac && swiftc -O -o aeasy-config AEasyConfig.swift

mac/aeasy-tray: mac/AEasyTray.swift
	cd mac && swiftc -O -o aeasy-tray AEasyTray.swift

apk: ## build the Android viewer app (needs Android SDK)
	cd android && $(GRADLE) :app:assembleDebug
	@echo "APK: android/app/build/outputs/apk/debug/app-debug.apk"

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
	rm -f mac/aeasy-server mac/aeasy-config mac/aeasy-tray
	rm -rf android/app/build android/.gradle android/build
