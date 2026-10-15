APP = build/NotiApp.app

build:
	mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/
	swiftc -O $(SWIFTFLAGS) Sources/*.swift -o $(APP)/Contents/MacOS/NotiApp
	codesign --force --sign - $(APP)

# same as install, plus a test-only hook scripts can use to click cards
debug: SWIFTFLAGS = -D DEBUG
debug: install

check:
	mkdir -p build
	swiftc -parse-as-library Sources/Detect.swift Sources/Usage.swift Tests/check.swift -o build/check
	build/check

install: build
	pkill -x NotiApp && sleep 1 || true
	rm -rf ~/Applications/NotiApp.app
	cp -R $(APP) ~/Applications/
	open ~/Applications/NotiApp.app

.PHONY: build check install debug
