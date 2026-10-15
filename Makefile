APP = build/Perch.app
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

build:
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Info.plist $(APP)/Contents/
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	# one app for Apple silicon and Intel Macs, running on macOS 14 Sonoma and later
	swiftc -O $(SWIFTFLAGS) -target arm64-apple-macos14.0 Sources/*.swift -o build/Perch-arm64
	swiftc -O $(SWIFTFLAGS) -target x86_64-apple-macos14.0 Sources/*.swift -o build/Perch-x86_64
	lipo -create build/Perch-arm64 build/Perch-x86_64 -output $(APP)/Contents/MacOS/Perch
	codesign --force --sign - $(APP)

# same as install, plus a test-only hook scripts can use to click cards
debug: SWIFTFLAGS = -D DEBUG
debug: install

check:
	mkdir -p build
	swiftc -parse-as-library Sources/Detect.swift Sources/Usage.swift Sources/Hooks.swift Tests/check.swift -o build/check
	build/check

# redraws Resources/AppIcon.icns from Tools/icon.swift
icon:
	mkdir -p build Resources
	swiftc -parse-as-library Tools/icon.swift Sources/Card.swift Sources/Detect.swift -o build/icon
	build/icon build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

# build/Perch.zip, ready to send to someone (see "Installing" in the README for opening it the first time)
dist: build
	ditto -c -k --keepParent $(APP) build/Perch.zip

# build/Perch.dmg: the usual window where you drag Perch onto Applications
dmg: build
	rm -rf build/dmg build/Perch.dmg
	mkdir -p build/dmg
	cp -R $(APP) build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname Perch -srcfolder build/dmg -ov -format UDZO build/Perch.dmg

# Publishes both on GitHub as v<CFBundleShortVersionString> from Info.plist. install.sh always fetches
# the newest release's Perch.zip, so bump the version in Info.plist before each release.
release: dist dmg
	gh release create v$(VERSION) build/Perch.zip build/Perch.dmg --title "Perch $(VERSION)" --generate-notes

install: build
	pkill -x Perch && sleep 1 || true
	pkill -x NotiApp && sleep 1 || true
	rm -rf ~/Applications/Perch.app ~/Applications/NotiApp.app
	cp -R $(APP) ~/Applications/
	open ~/Applications/Perch.app

.PHONY: build check icon dist dmg release install debug
