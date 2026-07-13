APP = build/Build/Products/Debug/Switchboard.app

.PHONY: generate build run logs

generate:
	xcodegen generate

build: generate
	xcodebuild -project Switchboard.xcodeproj -scheme Switchboard \
	  -configuration Debug -derivedDataPath build build

run: build
	-pkill -x Switchboard
	sleep 0.5
	open $(APP)

logs:
	log stream --predicate 'subsystem == "com.mattmilliken.switchboard"' --level debug
