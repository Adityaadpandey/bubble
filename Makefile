APP = build/NotiApp.app

build:
	mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/
	swiftc -O Sources/*.swift -o $(APP)/Contents/MacOS/NotiApp
	codesign --force --sign - $(APP)

check:
	mkdir -p build
	swiftc -parse-as-library Sources/Detect.swift Tests/check.swift -o build/check
	build/check

install: build
	pkill -x NotiApp && sleep 1 || true
	rm -rf ~/Applications/NotiApp.app
	cp -R $(APP) ~/Applications/
	open ~/Applications/NotiApp.app

.PHONY: build check install
