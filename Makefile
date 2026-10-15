APP = build/Notchy.app
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

build:
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Info.plist $(APP)/Contents/
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	# one app for Apple silicon and Intel Macs, running on macOS 14 Sonoma and later
	swiftc -O $(SWIFTFLAGS) -target arm64-apple-macos14.0 Sources/*.swift -o build/Notchy-arm64
	swiftc -O $(SWIFTFLAGS) -target x86_64-apple-macos14.0 Sources/*.swift -o build/Notchy-x86_64
	lipo -create build/Notchy-arm64 build/Notchy-x86_64 -output $(APP)/Contents/MacOS/Notchy
	codesign --force --sign - $(APP)

# same as install, plus a test-only hook scripts can use to click cards
debug: SWIFTFLAGS = -D DEBUG
debug: install

check:
	mkdir -p build
	swiftc -parse-as-library Sources/Detect.swift Sources/Usage.swift Sources/Hooks.swift Sources/Panes.swift Sources/Prefs.swift Sources/Risk.swift Sources/History.swift Sources/UpdateCheck.swift Tests/check.swift -o build/check
	build/check

# redraws Resources/AppIcon.icns from Tools/icon.swift
icon:
	mkdir -p build Resources
	swiftc -parse-as-library Tools/icon.swift Sources/Card.swift Sources/Detect.swift -o build/icon
	build/icon build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

# build/Notchy.zip, ready to send to someone (see "Installing" in the README for opening it the first time)
dist: build
	ditto -c -k --keepParent $(APP) build/Notchy.zip

# Publishes the zip on GitHub as v<CFBundleShortVersionString> from Info.plist. install.sh always fetches
# the newest release's Notchy.zip, so bump the version in Info.plist before each release.
# No disk image: Notchy isn't notarized, so anything opened from a browser download gets the
# "Apple could not verify" warning. The curl and brew installs never do, so those are the only ways in.
release: dist
	gh release create v$(VERSION) build/Notchy.zip --title "Notchy $(VERSION)" --generate-notes
	$(MAKE) cask

# Points the Homebrew cask (github.com/Adityaadpandey/homebrew-tap) at this version's zip, so
# `brew upgrade --cask notchy` picks it up, e.g. version "1.1" and that zip's sha256
cask:
	rm -rf build/tap
	git clone -q https://github.com/Adityaadpandey/homebrew-tap.git build/tap
	sed -i '' -e 's/^  version ".*"/  version "$(VERSION)"/' \
		-e "s/^  sha256 \".*\"/  sha256 \"$$(shasum -a 256 build/Notchy.zip | cut -d' ' -f1)\"/" build/tap/Casks/notchy.rb
	git -C build/tap commit -qam "notchy $(VERSION)"
	git -C build/tap -c credential.helper='!gh auth git-credential' push -q

install: build
	pkill -x Notchy && sleep 1 || true
	pkill -x Perch && sleep 1 || true
	rm -rf ~/Applications/Notchy.app ~/Applications/Perch.app
	cp -R $(APP) ~/Applications/
	open ~/Applications/Notchy.app

.PHONY: build check icon dist release cask install debug
