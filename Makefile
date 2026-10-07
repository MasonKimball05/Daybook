# Builds live outside ~/Documents: iCloud tags synced files with extended
# attributes, and codesign refuses to sign bundles that carry them.
CACHE := $(HOME)/Library/Caches/Daybook
BUILD := $(CACHE)/build
APP   := $(CACHE)/Daybook.app
# Sign with my Apple Development certificate when there is one, so macOS sees each
# rebuild as the same app and keeps the Calendars, Reminders and Mail permissions.
# (An ad hoc signature changes every build, and macOS would ask again each time.)
SIGN  := $(or $(shell security find-identity -v -p codesigning | awk '/Apple Development/ {print $$2; exit}'),-)

.PHONY: test app install icon ipa clean

test:
	swift test --scratch-path $(BUILD)

app:
	swift build -c release --scratch-path $(BUILD)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build -c release --scratch-path $(BUILD) --show-bin-path)/Daybook" $(APP)/Contents/MacOS/Daybook
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	codesign --force --sign $(SIGN) $(APP)

# Replaces ~/Applications/Daybook.app and opens it.
install: app
	-pkill -x Daybook
	rm -rf $(HOME)/Applications/Daybook.app
	mkdir -p $(HOME)/Applications
	ditto $(APP) $(HOME)/Applications/Daybook.app
	open $(HOME)/Applications/Daybook.app

# Redraws the app icons (iPhone and Mac) from Tools/make-icon.swift.
icon:
	swift Tools/make-icon.swift
	iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	rm -r Resources/AppIcon.iconset

# Packages the iPhone app for SideStore, which signs it with my Apple ID and
# refreshes it every week on its own. AirDrop build/Daybook.ipa to the iPhone
# (or put it in iCloud Drive) and open it with SideStore.
ipa:
	xcodegen generate
	xcodebuild -project Daybook.xcodeproj -scheme Daybook-iOS -sdk iphoneos -configuration Release \
		-derivedDataPath $(CACHE)/ios CODE_SIGNING_ALLOWED=NO build -quiet
	rm -rf $(CACHE)/ipa && mkdir -p $(CACHE)/ipa/Payload build
	ditto $(CACHE)/ios/Build/Products/Release-iphoneos/Daybook.app $(CACHE)/ipa/Payload/Daybook.app
	# Sign ad hoc with the entitlements (HealthKit), so SideStore sees them when it re-signs.
	codesign --force --sign - --entitlements Resources/Daybook-iOS.entitlements $(CACHE)/ipa/Payload/Daybook.app
	cd $(CACHE)/ipa && zip -qry Daybook.ipa Payload
	mv $(CACHE)/ipa/Daybook.ipa build/Daybook.ipa
	@echo "Built build/Daybook.ipa"

clean:
	rm -rf $(CACHE)
