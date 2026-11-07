APP       := Pounce
VERSION   := 1.3.0
BUILD     := build
BUNDLE    := $(BUILD)/$(APP).app
BINARY    := $(BUNDLE)/Contents/MacOS/$(APP)
DMG       := $(BUILD)/$(APP).dmg
PREFIX    ?= /Applications

SWIFTC    := swiftc
MIN_MACOS := 27.0
TARGET    := -target arm64-apple-macos$(MIN_MACOS) -swift-version 6

CORE_SRC  := $(wildcard Sources/Core/*.swift)
APP_SRC   := $(wildcard Sources/App/*.swift)

# Small and fast: one optimized module, no reflection metadata, unused code stripped.
SWIFTFLAGS := $(TARGET) -Osize -wmo -Xfrontend -disable-reflection-metadata -Xlinker -dead_strip -warnings-as-errors

# Code signing identity: "-" (ad hoc) for local builds. Releases are signed with the project's own certificate
# (SHA-1 below), so every version has the same designated requirement: macOS keeps Pounce's login item across
# updates, and Homebrew sees the same signer when it upgrades the cask.
RELEASE_ID    := FA3A2946AEFA935A257B843235DD55576AAD9870
SIGN_ID       ?= -
SIGN_KEYCHAIN ?=
SIGN          := codesign --force --sign "$(SIGN_ID)" $(if $(SIGN_KEYCHAIN),--keychain "$(SIGN_KEYCHAIN)") --timestamp=none

ICON      := resources/$(APP).icns
RESOURCES := $(BUNDLE)/Contents/Info.plist $(if $(wildcard $(ICON)),$(BUNDLE)/Contents/Resources/$(APP).icns)

.PHONY: all app dmg release run test harness install uninstall icon clean

all: app

app: $(BUILD)/.signed

# Sign whenever something in the bundle changed.
$(BUILD)/.signed: $(BINARY) $(RESOURCES)
	@$(SIGN) $(BUNDLE)
	@touch $@
	@echo "Built $(BUNDLE) ($$(du -sh $(BUNDLE) | cut -f1))"

$(BINARY): $(CORE_SRC) $(APP_SRC)
	@mkdir -p $(@D)
	$(SWIFTC) $(SWIFTFLAGS) -module-name $(APP) $^ -o $@
	@strip -x $@

$(BUNDLE)/Contents/Info.plist: resources/Info.plist Makefile
	@mkdir -p $(@D)
	@sed -e 's/__VERSION__/$(VERSION)/g' -e 's/__IDENTIFIER__/app.pounce.Pounce/g' -e 's/__NAME__/$(APP)/g' $< > $@

$(BUNDLE)/Contents/Resources/$(APP).icns: $(ICON)
	@mkdir -p $(@D)
	@cp $< $@

# A disk image to drag Pounce into Applications from.
dmg: app
	@rm -rf $(BUILD)/dmg $(DMG)
	@mkdir -p $(BUILD)/dmg
	@ditto $(BUNDLE) $(BUILD)/dmg/$(APP).app
	@ln -s /Applications $(BUILD)/dmg/Applications
	@hdiutil create -quiet -volname $(APP) -srcfolder $(BUILD)/dmg -fs HFS+ -format ULMO -ov $(DMG)
	@rm -rf $(BUILD)/dmg
	@echo "Built $(DMG) ($$(du -sh $(DMG) | cut -f1))"

# Certificate-signed app and disk image for GitHub releases (see .github/workflows/release.yml).
release:
	@$(MAKE) clean
	@$(MAKE) dmg SIGN_ID="$(RELEASE_ID)" SIGN_KEYCHAIN="$(SIGN_KEYCHAIN)" VERSION="$(VERSION)"
	@codesign --verify --deep --strict $(BUNDLE)
	@codesign -d -r- $(BUNDLE) 2>&1 | grep -q 'certificate leaf' || (echo "release is not certificate-signed" && false)
	@test "$$(lipo -archs $(BINARY))" = arm64 || (echo "release is not arm64 only" && false)
	@vtool -show-build $(BINARY) | grep -q "minos $(MIN_MACOS)" || (echo "release has the wrong minimum macOS" && false)

# Unit tests for the core (calculator, matching, ranking), with AddressSanitizer and UndefinedBehaviorSanitizer.
test: $(BUILD)/tests
	@$(BUILD)/tests

$(BUILD)/tests: $(CORE_SRC) tests/main.swift
	@mkdir -p $(@D)
	$(SWIFTC) $(TARGET) -Onone -g -sanitize=address,undefined -module-name PounceTests $^ -o $@

# A copy for automated testing, with its own bundle id and settings. It takes commands from a pipe and its window
# never takes the keyboard, so it can't catch what someone types elsewhere. See Sources/Harness.
HARNESS := $(BUILD)/PounceTest.app
harness: $(CORE_SRC) $(APP_SRC) $(wildcard Sources/Harness/*.swift) resources/Info.plist
	@mkdir -p $(HARNESS)/Contents/MacOS $(HARNESS)/Contents/Resources
	$(SWIFTC) $(TARGET) -Osize -wmo -D HARNESS -module-name $(APP) $(CORE_SRC) $(APP_SRC) $(wildcard Sources/Harness/*.swift) \
		-o $(HARNESS)/Contents/MacOS/$(APP)
	@sed -e 's/__VERSION__/$(VERSION)/g' -e 's/__IDENTIFIER__/app.pounce.PounceTest/g' -e 's/__NAME__/PounceTest/g' resources/Info.plist \
		> $(HARNESS)/Contents/Info.plist
	@if [ -f $(ICON) ]; then cp $(ICON) $(HARNESS)/Contents/Resources/; fi
	@codesign --force --sign - --entitlements resources/debug.entitlements $(HARNESS)
	@echo "Built $(HARNESS)"

run: app
	@pkill -f "$(abspath $(BUNDLE))/Contents/MacOS/$(APP)" || true
	@open $(BUNDLE)

install: app
	@pkill -f "$(PREFIX)/$(APP).app/Contents/MacOS/$(APP)" || true
	@rm -rf "$(PREFIX)/$(APP).app"
	@ditto $(BUNDLE) "$(PREFIX)/$(APP).app"
	@open "$(PREFIX)/$(APP).app"
	@echo "Installed $(PREFIX)/$(APP).app"

uninstall:
	@pkill -f "$(PREFIX)/$(APP).app/Contents/MacOS/$(APP)" || true
	@rm -rf "$(PREFIX)/$(APP).app"

icon: tools/icon.swift
	@mkdir -p $(BUILD)
	$(SWIFTC) $(TARGET) -O $< -o $(BUILD)/icon
	@$(BUILD)/icon $(ICON) docs/icon.png
	@echo "Wrote $(ICON) ($$(du -h $(ICON) | cut -f1))"

clean:
	rm -rf $(BUILD)
