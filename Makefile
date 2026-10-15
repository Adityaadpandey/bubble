APP = build/Perch.app

build:
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Info.plist $(APP)/Contents/
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	swiftc -O $(SWIFTFLAGS) Sources/*.swift -o $(APP)/Contents/MacOS/Perch
	codesign --force --sign - $(APP)

# same as install, plus a test-only hook scripts can use to click cards
debug: SWIFTFLAGS = -D DEBUG
debug: install

check:
	mkdir -p build
	swiftc -parse-as-library Sources/Detect.swift Sources/Usage.swift Tests/check.swift -o build/check
	build/check

# redraws Resources/AppIcon.icns from Tools/icon.swift
icon:
	mkdir -p build Resources
	swiftc -parse-as-library Tools/icon.swift Sources/Card.swift Sources/Detect.swift -o build/icon
	build/icon build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

install: build
	pkill -x Perch && sleep 1 || true
	pkill -x NotiApp && sleep 1 || true
	rm -rf ~/Applications/Perch.app ~/Applications/NotiApp.app
	cp -R $(APP) ~/Applications/
	open ~/Applications/Perch.app

.PHONY: build check icon install debug
